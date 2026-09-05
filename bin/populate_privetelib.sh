#!/usr/bin/env bash

###############################################################################
# bin/populate_privetelib.sh
#
# Version:       1.1.0
# Last updated:  2026-09-04
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Rebuild the app-registered personal library database (privetelib) from
#   the on-disk Books collection (Phase 1 of docs/REPRESENTATION_PLAN.md).
#   privetelib is the sibling library the MultiLib desktop app created with
#   the Flibusta plugin: same 17-table ml* schema as flibusta, connectable
#   from the app.  The population contract:
#
#       * flibusta and mllbr_main are NEVER written - read-only source
#       * ONLY books present in the Books folder are represented - no
#         exact-copy of the flibusta catalog
#       * the tool manages ONLY the pure catalog tables it populates;
#         app-owned tables (mlactual, mldownloaddata, mlnews*, mluser*)
#         are never touched
#       * rebuild semantics: managed tables are cleared and reloaded per
#         run - idempotent by construction, no drift
#
#   Matching is md5-exact (the strongest tier): every book file on disk is
#   hashed (zip-wrapped FB2 by its decompressed content, loose *.fb2
#   directly) and resolved against flibusta.mlbook.md5, which the dump
#   pipeline populates for ALL 869,130 catalog rows.  A single
#   (md5, bookid) map is pulled once and joined locally - no per-file
#   queries.
#
#   KEY STRATEGY (v1.1.0 rewrite): privetelib's own AUTO_INCREMENT columns
#   generate EVERY key.  The v1.0.0 "exact copy" approach (INSERT ... SELECT
#   * carrying flibusta's ids wholesale) is gone - copied foreign ids broke
#   the app's key bookkeeping, which is exactly why MultiLib.exe showed
#   catalog basics but no books.  Now the tool emits one INSERT per row,
#   captures the freshly generated id with LAST_INSERT_ID() into a session
#   variable (@bid_<old>, @aid_<old>, @gid_<old>, @sid_<old>), and child
#   rows (mlauthor, mlgenre, mlseq, mlrating, mlcustinfo) reference ONLY
#   those captured ids - keys are used only after they come into existence.
#   The whole rebuild runs as a single SQL script in one client session, so
#   the variables live for the entire run; TRUNCATE at the top resets the
#   auto-increment counters, making every run a clean rebuild.
#
#   Reference entities are inserted for OUR books only:
#       mlauthorname  <- distinct authors of the resolved bookids
#       mlgenrename   <- distinct genres, parentgenreid remapped to the
#                        freshly generated parent id (or NULL when the
#                        parent genre is not part of the personal library),
#                        emitted parent-first so @gid_* exists when used
#       mlseqname     <- distinct series of the resolved bookids
#   Per-book tables, in strict dependency order:
#       mlbook        <- one row per resolved book; filename/arcname carry
#                        the REAL on-disk relative path (e.g.
#                        "А/Аб/Абби Линн/Series X/0Мироходец.zip") and the
#                        zip member name (arcname is empty for loose .fb2);
#                        library='privetelib', filesize = on-disk bytes,
#                        ext='fb2' (content format), all catalog metadata
#                        (title, lang, md5, pi_*, ...) copied verbatim
#       mlauthor      <- (new bookid, new authorid, role)
#       mlgenre       <- (new bookid, new genreid)
#       mlseq         <- (new bookid, new seqid, seqnum)
#       mlrating      <- per-book aggregate rating copied from
#                        flibusta.mlrating - the per-book CHAR(1) rating
#                        produced by BookTracker-import/sql/
#                        Flibusta_Load_mlrating.sql (librate, the raw
#                        per-user source, is dropped by the ingest cleanup,
#                        so the aggregate is the authoritative source)
#       mlcustinfo    <- di_history / custominfo for our books
#
#   mlcoverpage / mldescription are NOT populated: the source catalog has
#   them EMPTY (covers/descriptions are not part of the loaded dump).
#
#   Because every table is interdependent through the generated keys, a
#   column-parity mismatch on ANY managed table aborts the run (before any
#   TRUNCATE) instead of silently skipping - a partial rebuild would leave
#   dangling key references.
#
#   After population, switch MultiLib.exe to privetelib to browse the
#   personal collection with ratings/series/genres, and - with the real
#   paths in mlbook.filename/arcname - try opening a book from the app.
#
#   The MariaDB lifecycle is shared with the rest of the toolchain
#   (lib/mariadb_lifecycle.sh): a server that is down is started
#   (elevated PowerShell) and, because this tool started it, stopped
#   again on exit; a server that was already running is left untouched.
#   --dry-run walks + resolves and reports, but writes no report file,
#   truncates nothing and inserts nothing.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/populate_privetelib.sh [options]
#
#   Options:
#       -n, --dry-run        walk + resolve + summarize, change nothing
#       -d, --debug          print verbose diagnostics to stderr
#       -h, --help           show this help
#       -v, --version        print version and exit
#
#   Exit codes:
#       0   success (or --dry-run)
#       1   operational failure (client missing, server down, no match map,
#           column-parity mismatch, rebuild error)
#       2   usage error
#
#   Environment / config (config/populate_privetelib.conf; all overridable):
#       POP_LIBRARY_ROOT   the personal Books tree (default: /mnt/c/Backup_Go7/Books)
#       POP_REPORT_DIR     where the per-run TSV report goes
#                          (default: /mnt/c/Backup_Go7/merge-reports)
#       POP_SOURCE_DB      read-only catalog DB (default: flibusta)
#       POP_TARGET_DB      the library DB to rebuild (default: privetelib)
#       POP_CHUNK          bookids per read query IN-list (default: 500)
#       MYSQL_CLIENT / MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD /
#       MYSQL_EXTRA_ARGS   same contract as BookTracker-import
#       MYSQL_CONNECT_TIMEOUT  mysql client TCP connect bound in seconds (default: 10)
#       MARIA_*            lifecycle settings (see lib/mariadb_lifecycle.sh)
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# --- defaults (same contract as the rest of the toolchain) --------------------
MYSQL_CLIENT="${MYSQL_CLIENT:-mysql}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_EXTRA_ARGS="${MYSQL_EXTRA_ARGS:---default-character-set=utf8}"
MYSQL_CONNECT_TIMEOUT="${MYSQL_CONNECT_TIMEOUT:-10}"

# --- config file ---------------------------------------------------------------
CONF_FILE="${CONF_FILE:-$PROJECT_ROOT/config/populate_privetelib.conf}"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

POP_LIBRARY_ROOT="${POP_LIBRARY_ROOT:-/mnt/c/Backup_Go7/Books}"
POP_REPORT_DIR="${POP_REPORT_DIR:-/mnt/c/Backup_Go7/merge-reports}"
POP_SOURCE_DB="${POP_SOURCE_DB:-flibusta}"
POP_TARGET_DB="${POP_TARGET_DB:-privetelib}"
POP_CHUNK="${POP_CHUNK:-500}"

DRY_RUN=0
DEBUG=0

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
debug() { if (( DEBUG )); then log "debug: $*"; fi; }
die()  { log "error: $*"; exit 1; }

# --- shared MariaDB lifecycle (lib/mariadb_lifecycle.sh) -----------------------
# shellcheck source=../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/populate.XXXXXX")"
cleanup() {
    rm -rf "$tmp"
    mariadb_stop_if_started
    return 0
}
trap cleanup EXIT

# --- build client argv (password never included) --------------------------------
mysql_args=("$MYSQL_CLIENT")
[[ -n "${MYSQL_HOST:-}" ]] && mysql_args+=(-h "$MYSQL_HOST" --protocol=TCP)
[[ -n "${MYSQL_PORT:-}" ]] && mysql_args+=(-P "$MYSQL_PORT")
[[ -n "${MYSQL_USER:-}" ]] && mysql_args+=(-u "$MYSQL_USER")
[[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && mysql_args+=("$MYSQL_EXTRA_ARGS")
mysql_args+=(--connect-timeout="$MYSQL_CONNECT_TIMEOUT")
# Pin the session charset: the server may transcode to its own default
# (cp1251) otherwise, corrupting UTF-8 payloads.
charset="utf8"
case " ${MYSQL_EXTRA_ARGS:-} " in
    *" --default-character-set="*)
        charset="${MYSQL_EXTRA_ARGS##*--default-character-set=}"
        charset="${charset%% *}" ;;
esac
mysql_args+=(--init-command="SET NAMES $charset")

# Run the mysql client argv; stdin passes through.
run_mysql() { # [args...]
    local -a a=("$@")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${a[@]}"
    else
        "${a[@]}"
    fi
}

# --- helpers ----------------------------------------------------------------------
db_exists() { # db -> 0/1
    local db="$1" out
    out="$(run_mysql "${mysql_args[@]}" -B --skip-column-names \
        -e "SHOW DATABASES LIKE '$db'" 2>/dev/null || true)"
    [[ "$out" == "$db" ]]
}

columns_of() { # db table -> comma-separated "name:type" list (or empty)
    local db="$1" table="$2"
    run_mysql "${mysql_args[@]}" -B --skip-column-names \
        -e "SELECT GROUP_CONCAT(CONCAT(COLUMN_NAME, ':', DATA_TYPE) ORDER BY ORDINAL_POSITION SEPARATOR ',') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$db' AND TABLE_NAME='$table'" \
        2>/dev/null || true
}

managed_all=(mlauthorname mlgenrename mlseqname mlbook mlauthor mlgenre mlseq mlrating mlcustinfo)

# --- 1. fetch the (md5, bookid) map from the catalog -----------------------------
# One bounded read of the whole map (869k rows), joined locally - per-file
# lookups would each be a full table scan (no index on mlbook.md5).
fetch_md5_map() {
    local rc=0 attempt
    : > "$tmp/map_raw.tsv"
    for attempt in 1 2; do
        rc=0
        if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
            MYSQL_PWD="$MYSQL_PASSWORD" timeout "${POP_MAP_TIMEOUT:-180}" \
                "${mysql_args[@]}" -B --skip-column-names --raw \
                -e "SELECT md5, bookid FROM $POP_SOURCE_DB.mlbook" \
                > "$tmp/map_raw.tsv" 2> "$tmp/map_err.txt" || rc=$?
        else
            timeout "${POP_MAP_TIMEOUT:-180}" \
                "${mysql_args[@]}" -B --skip-column-names --raw \
                -e "SELECT md5, bookid FROM $POP_SOURCE_DB.mlbook" \
                > "$tmp/map_raw.tsv" 2> "$tmp/map_err.txt" || rc=$?
        fi
        if (( rc == 0 )) && [[ -s "$tmp/map_raw.tsv" ]]; then
            break
        fi
        log "warn : md5 map fetch failed (attempt $attempt/2): $(head -n 1 "$tmp/map_err.txt" 2>/dev/null || true)"
        if (( attempt == 1 )); then
            log "warn : retrying once..."
            sleep 2
        fi
    done
    if (( rc != 0 )) || [[ ! -s "$tmp/map_raw.tsv" ]]; then
        return 1
    fi
    # dedupe: an md5 can map to several bookids (catalog duplicates); keep the
    # lowest bookid and record the collisions for the report
    : > "$tmp/dupes.txt"
    awk -F'\t' -v dup_f="$tmp/dupes.txt" '
    {
        md5 = $1; bid = $2
        if (md5 == "" || bid == "" || bid !~ /^[0-9]+$/) next
        if (!(md5 in min)) { min[md5] = bid }
        else {
            if (bid < min[md5]) min[md5] = bid
            if (!(md5 in dup)) { dup[md5] = 1; print md5 > dup_f }
        }
    }
    END { for (m in min) print m "\t" min[m] }
    ' "$tmp/map_raw.tsv" | LC_ALL=C sort > "$tmp/map.tsv"
    local rows dupes
    rows="$(wc -l < "$tmp/map.tsv" | tr -d ' ')"
    dupes="$(wc -l < "$tmp/dupes.txt" | tr -d ' ')"
    debug "catalog md5 map: $rows distinct md5(s), $dupes md5(s) with duplicate bookids (lowest kept)"
    return 0
}

# --- 2. walk the library: hash every book file ------------------------------------
# *.zip  -> md5 of the DECOMPRESSED content (unzip -p, zcat fallback) +
#           member name (arcname) via `unzip -Z1`
# *.fb2  -> md5 of the file itself; arcname empty
# everything else (desktop.ini, hidden, unknown ext) -> skipped
# files.tsv columns: rel \t md5 \t status \t kind \t arcname \t size
do_walk() {
    local f rel base h arc size
    : > "$tmp/files.tsv"
    while IFS= read -r f; do
        rel="${f#"$POP_LIBRARY_ROOT"/}"
        base="${rel##*/}"
        [[ "$base" == .* ]] && continue
        [[ "${base,,}" == desktop.ini ]] && continue
        size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        case "$base" in
            *.zip|*.ZIP)
                # `|| true` everywhere: set -euo pipefail would otherwise abort
                # the walk when unzip fails on an unreadable zip
                h="$(unzip -p "$f" 2>/dev/null | md5sum | awk '{print $1}' || true)"
                if [[ ! "$h" =~ ^[0-9a-f]{32}$ ]]; then
                    h="$(zcat "$f" 2>/dev/null | md5sum | awk '{print $1}' || true)"
                fi
                arc="$(unzip -Z1 "$f" 2>/dev/null | head -n1 || true)"
                if [[ "$h" =~ ^[0-9a-f]{32}$ ]]; then
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$h" ok zip "${arc:-}" "$size" >> "$tmp/files.tsv"
                else
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "-" corrupt zip "${arc:-}" "$size" >> "$tmp/files.tsv"
                fi
                ;;
            *.fb2|*.FB2)
                h="$(md5sum "$f" 2>/dev/null | awk '{print $1}' || true)"
                if [[ "$h" =~ ^[0-9a-f]{32}$ ]]; then
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$h" ok fb2 "-" "$size" >> "$tmp/files.tsv"
                else
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "-" corrupt fb2 "-" "$size" >> "$tmp/files.tsv"
                fi
                ;;
            *)
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "-" skipped "${base##*.}" "-" "$size" >> "$tmp/files.tsv"
                ;;
        esac
    done < <(find "$POP_LIBRARY_ROOT" -type f | LC_ALL=C sort)
    local scanned zips fb2 skip corrupt
    scanned="$(wc -l < "$tmp/files.tsv" | tr -d ' ')"
    zips="$(awk -F'\t' '$4 == "zip" {c++} END {print c+0}' "$tmp/files.tsv")"
    fb2="$(awk -F'\t' '$4 == "fb2" {c++} END {print c+0}' "$tmp/files.tsv")"
    skip="$(awk -F'\t' '$3 == "skipped" {c++} END {print c+0}' "$tmp/files.tsv")"
    corrupt="$(awk -F'\t' '$3 == "corrupt" {c++} END {print c+0}' "$tmp/files.tsv")"
    debug "walk: $scanned file(s) - $zips zip, $fb2 fb2, $skip skipped, $corrupt corrupt"
}

# --- 3. resolve: join the walked files against the md5 map -------------------------
# resolved.tsv columns: rel \t md5 \t bookid \t status \t arcname \t size \t kind
do_resolve() {
    : > "$tmp/resolved.tsv"
    gawk -F'\t' -v map_f="$tmp/map.tsv" '
    FILENAME == map_f { m[$1] = $2; next }
    {
        rel = $1; h = $2; st = $3; kind = $4; arc = $5; sz = $6
        if (st != "ok") { print rel "\t" h "\t-\t" st "\t" arc "\t" sz "\t" kind; next }
        if (h in m) print rel "\t" h "\t" m[h] "\tmatched\t" arc "\t" sz "\t" kind
        else        print rel "\t" h "\t-\tunmatched\t" arc "\t" sz "\t" kind
    }
    ' "$tmp/map.tsv" "$tmp/files.tsv" | LC_ALL=C sort > "$tmp/resolved.tsv"
    local matched unmatched
    matched="$(awk -F'\t' '$4 == "matched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
    unmatched="$(awk -F'\t' '$4 == "unmatched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
    debug "resolve: $matched file(s) matched, $unmatched unmatched"
}

# --- 4. column-parity gate -----------------------------------------------------------
# Every managed table is interdependent through the generated keys, so a
# mismatch on ANY table aborts the run BEFORE any TRUNCATE - a partial
# rebuild would leave dangling key references.
check_parity_all() {
    local t fa fb bad=0
    for t in "${managed_all[@]}"; do
        fa="$(columns_of "$POP_SOURCE_DB" "$t")"
        fb="$(columns_of "$POP_TARGET_DB" "$t")"
        if [[ -z "$fa" ]] || [[ "$fa" != "$fb" ]]; then
            log "warn : column mismatch for $t (source '$fa' vs target '$fb')"
            bad=1
        fi
    done
    if (( bad )); then
        die "column parity mismatch on one or more managed tables; fix $POP_TARGET_DB schema and retry"
    fi
    log "info : column parity OK for all ${#managed_all[@]} managed tables"
}

# --- 5. generate the rebuild SQL script -----------------------------------------------
# One script, one client session: TRUNCATE resets the auto-increment counters,
# then every INSERT generates a fresh key and captures it with LAST_INSERT_ID()
# into a session variable that later statements reference.
# SQL literal helpers (shared by every emitter; note the octal "\047" is a
# single quote - the awk programs contain no literal quote characters):
#   esc()  double backslashes then double single quotes (SQL string escaping)
#   q()    quote a value, or pass NULL through (mysql -B prints NULL as "NULL")
#   num()  emit an integer unquoted, empty as 0, else quoted
generate_rebuild_sql() {
    local sql_f="$tmp/rebuild.sql"
    local -a chunk
    local i inlist t

    mapfile -t BIDS < "$tmp/bookids.txt"
    if (( ${#BIDS[@]} == 0 )); then
        log "warn : no resolved bookids; nothing to rebuild into $POP_TARGET_DB"
        return 0
    fi

    check_parity_all

    : > "$sql_f"
    {
        echo "SET NAMES utf8;"
        echo "SET FOREIGN_KEY_CHECKS = 0;"
        for t in "${managed_all[@]}"; do
            echo "TRUNCATE TABLE $POP_TARGET_DB.$t;"
        done
    } >> "$sql_f"

    # --- read catalog data (chunked by POP_CHUNK bookids) ---
    for f in authors genres seqs book_cat mlauthor_t mlgenre_t mlseq_t mlrating_t mlcustinfo_t; do
        : > "$tmp/$f.tsv"
    done
    for (( i = 0; i < ${#BIDS[@]}; i += POP_CHUNK )); do
        chunk=("${BIDS[@]:i:POP_CHUNK}")
        inlist="$(IFS=,; echo "${chunk[*]}")"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT DISTINCT a.authorid, an.FirstName, an.MiddleName, an.LastName, an.NickName, an.FullName, an.Email, an.TotalCount, an.NormalCount FROM $POP_SOURCE_DB.mlauthor a JOIN $POP_SOURCE_DB.mlauthorname an ON an.authorid = a.authorid WHERE a.bookid IN ($inlist)" \
            >> "$tmp/authors.tsv" || die "author read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT DISTINCT g.genreid, gn.parentgenreid, gn.genrecode, gn.genrenamerus, gn.TotalCount, gn.NormalCount FROM $POP_SOURCE_DB.mlgenre g JOIN $POP_SOURCE_DB.mlgenrename gn ON gn.genreid = g.genreid WHERE g.bookid IN ($inlist)" \
            >> "$tmp/genres.tsv" || die "genre read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT DISTINCT s.seqid, sn.seqname, sn.TotalCount, sn.NormalCount FROM $POP_SOURCE_DB.mlseq s JOIN $POP_SOURCE_DB.mlseqname sn ON sn.seqid = s.seqid WHERE s.bookid IN ($inlist)" \
            >> "$tmp/seqs.tsv" || die "series read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlbook WHERE bookid IN ($inlist)" \
            >> "$tmp/book_cat.tsv" || die "catalog read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlauthor WHERE bookid IN ($inlist)" \
            >> "$tmp/mlauthor_t.tsv" || die "mlauthor read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlgenre WHERE bookid IN ($inlist)" \
            >> "$tmp/mlgenre_t.tsv" || die "mlgenre read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlseq WHERE bookid IN ($inlist)" \
            >> "$tmp/mlseq_t.tsv" || die "mlseq read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlrating WHERE bookid IN ($inlist)" \
            >> "$tmp/mlrating_t.tsv" || die "mlrating read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlcustinfo WHERE bookid IN ($inlist)" \
            >> "$tmp/mlcustinfo_t.tsv" || die "mlcustinfo read failed"
    done
    # dedupe across chunks (an entity can span several chunks)
    LC_ALL=C sort -u -t $'\t' -k1,1 "$tmp/authors.tsv"      -o "$tmp/authors.tsv"
    LC_ALL=C sort -u -t $'\t' -k1,1 "$tmp/genres.tsv"       -o "$tmp/genres.tsv"
    LC_ALL=C sort -u -t $'\t' -k1,1 "$tmp/seqs.tsv"         -o "$tmp/seqs.tsv"
    LC_ALL=C sort -u -t $'\t' -k1,1 "$tmp/book_cat.tsv"     -o "$tmp/book_cat.tsv"
    LC_ALL=C sort -u "$tmp/mlauthor_t.tsv"                  -o "$tmp/mlauthor_t.tsv"
    LC_ALL=C sort -u "$tmp/mlgenre_t.tsv"                   -o "$tmp/mlgenre_t.tsv"
    LC_ALL=C sort -u "$tmp/mlseq_t.tsv"                     -o "$tmp/mlseq_t.tsv"
    LC_ALL=C sort -u "$tmp/mlrating_t.tsv"                  -o "$tmp/mlrating_t.tsv"
    LC_ALL=C sort -u "$tmp/mlcustinfo_t.tsv"                -o "$tmp/mlcustinfo_t.tsv"

    local T="$POP_TARGET_DB"
    local AWK_HELPERS='function esc(s,   r) { r = s; gsub(/\\/, "\\\\", r); gsub("\047", "\047\047", r); return r }
function q(s)   { if (s == "NULL") return "NULL"; return "\047" esc(s) "\047" }
function num(s) { if (s == "NULL") return "NULL"; if (s ~ /^-?[0-9]+$/) return s; if (s == "") return "0"; return "\047" esc(s) "\047" }'

    # 5.1 mlauthorname: distinct authors, fresh authorid captured as @aid_<old>
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    {
        printf "INSERT INTO %s.mlauthorname (FirstName,MiddleName,LastName,NickName,FullName,Email,TotalCount,NormalCount) VALUES (%s,%s,%s,%s,%s,%s,%s,%s);\n", T, q($2),q($3),q($4),q($5),q($6),q($7),num($8),num($9)
        printf "SET @aid_%s = LAST_INSERT_ID();\n", $1
    }' "$tmp/authors.tsv" >> "$sql_f"

    # 5.2 mlgenrename: distinct genres, fresh genreid captured as @gid_<old>;
    #     parentgenreid remapped to the fresh parent id when the parent genre
    #     is part of the personal library (parents emitted first), else NULL
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    function emit(i,   p) {
        p = (par[i] == "" || !(par[i] in em)) ? "NULL" : ("@gid_" par[i])
        printf "INSERT INTO %s.mlgenrename (parentgenreid,genrecode,genrenamerus,TotalCount,NormalCount) VALUES (%s,%s,%s,%s,%s);\n", T, p, q(code[i]), q(name[i]), num(tc[i]), num(nc[i])
        printf "SET @gid_%s = LAST_INSERT_ID();\n", id[i]
    }
    {
        n++
        id[n]=$1; par[n]=($2 == "NULL" ? "" : $2)
        code[n]=$3; name[n]=$4; tc[n]=$5; nc[n]=$6
        used[$1]=1
    }
    END {
        # parent-first topological order so @gid_<parent> exists when used
        while (1) {
            prog = 0
            for (i = 1; i <= n; i++) {
                if (done[i]) continue
                if (par[i] == "" || ((par[i] in used) && (par[i] in em))) {
                    emit(i); done[i]=1; em[id[i]]=1; prog=1
                }
            }
            if (!prog) break
        }
        # dangling parents (not used in the personal library) -> NULL
        for (i = 1; i <= n; i++) if (!done[i]) { emit(i); done[i]=1; em[id[i]]=1 }
    }' "$tmp/genres.tsv" >> "$sql_f"

    # 5.3 mlseqname: distinct series, fresh seqid captured as @sid_<old>
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    {
        printf "INSERT INTO %s.mlseqname (seqname,TotalCount,NormalCount) VALUES (%s,%s,%s);\n", T, q($2), num($3), num($4)
        printf "SET @sid_%s = LAST_INSERT_ID();\n", $1
    }' "$tmp/seqs.tsv" >> "$sql_f"

    # 5.4 mlbook: one row per resolved book; real on-disk filename/arcname;
    #     fresh bookid captured as @bid_<old>; catalog metadata verbatim.
    #     book_cat.tsv = SELECT * (26 columns, bookid first); resolved.tsv
    #     carries the walk data (rel, arc, size) per file.
    awk -F'\t' -v T="$T" -v CAT="$tmp/book_cat.tsv" "$AWK_HELPERS"'
    FILENAME == CAT {
        for (i = 1; i <= 26; i++) c[$1,i] = $i
        have[$1] = 1
        next
    }
    {
        rel = $1; bid = $3; st = $4; arc = $5; sz = $6
        if (st != "matched") next
        if (bid in done) next          # duplicate copies of the same book
        if (!(bid in have)) { miss[bid] = 1; next }
        done[bid] = 1
        printf "INSERT INTO %s.mlbook (library,title,lang,date_in,filename,filesize,arcname,ext,deleted,md5,srclang,date_wr,keywords,di_progused,di_date,di_srcurl,di_srcosr,di_author,di_id,di_version,pi_bookname,pi_publisher,pi_city,pi_year,pi_isbn) VALUES (\047privetelib\047,%s,%s,%s,%s,%s,%s,\047fb2\047,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s);\n", T, q(c[bid,3]),q(c[bid,4]),q(c[bid,5]),q(rel),num(sz),q(arc),q(c[bid,10]),q(c[bid,11]),q(c[bid,12]),q(c[bid,13]),q(c[bid,14]),q(c[bid,15]),q(c[bid,16]),q(c[bid,17]),q(c[bid,18]),q(c[bid,19]),q(c[bid,20]),q(c[bid,21]),q(c[bid,22]),q(c[bid,23]),q(c[bid,24]),q(c[bid,25]),q(c[bid,26])
        printf "SET @bid_%s = LAST_INSERT_ID();\n", bid
    }
    END { for (b in miss) print "warn: bookid " b " resolved but absent from catalog; skipped" > "/dev/stderr" }
    ' "$tmp/book_cat.tsv" "$tmp/resolved.tsv" >> "$sql_f"

    # 5.5 mlauthor: (fresh bookid, fresh authorid, role)
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    { printf "INSERT INTO %s.mlauthor (bookid,authorid,role) VALUES (@bid_%s,@aid_%s,%s);\n", T, $2, $3, q($4) }' "$tmp/mlauthor_t.tsv" >> "$sql_f"

    # 5.6 mlgenre: (fresh bookid, fresh genreid)
    awk -F'\t' -v T="$T" '
    { printf "INSERT INTO %s.mlgenre (bookid,genreid) VALUES (@bid_%s,@gid_%s);\n", T, $2, $3 }' "$tmp/mlgenre_t.tsv" >> "$sql_f"

    # 5.7 mlseq: (fresh bookid, fresh seqid, seqnum)
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    { printf "INSERT INTO %s.mlseq (bookid,seqid,seqnum) VALUES (@bid_%s,@sid_%s,%s);\n", T, $2, $3, num($4) }' "$tmp/mlseq_t.tsv" >> "$sql_f"

    # 5.8 mlrating: per-book aggregate from flibusta.mlrating (the output of
    #     BookTracker-import/sql/Flibusta_Load_mlrating.sql); only books
    #     that have a rating get a row
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    { printf "INSERT INTO %s.mlrating (bookid,rating) VALUES (@bid_%s,%s);\n", T, $2, q($3) }' "$tmp/mlrating_t.tsv" >> "$sql_f"

    # 5.9 mlcustinfo: di_history / custominfo for our books
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    { printf "INSERT INTO %s.mlcustinfo (bookid,di_history,custominfo) VALUES (@bid_%s,%s,%s);\n", T, $2, q($3), q($4) }' "$tmp/mlcustinfo_t.tsv" >> "$sql_f"

    local lines
    lines="$(wc -l < "$sql_f" | tr -d ' ')"
    debug "generated rebuild script: $lines lines, ${#BIDS[@]} bookid(s)"
}

# --- 6. per-run report + summary ------------------------------------------------------
do_report() {
    local stamp report_name report_path
    stamp="$(date '+%Y%m%d-%H%M%S')"
    report_name="populate_privetelib_$stamp.tsv"
    report_path="$POP_REPORT_DIR/$report_name"
    if (( DRY_RUN )); then
        log "dry-run: report would be written to $report_path"
        return 0
    fi
    mkdir -p "$POP_REPORT_DIR"
    {
        printf 'processed_at\tsource_file\tmd5\tbookid\tstatus\n'
        local ts
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        awk -F'\t' -v ts="$ts" '{ print ts "\t" $1 "\t" $2 "\t" $3 "\t" $4 }' "$tmp/resolved.tsv"
    } > "$report_path"
    log "info : report written to $report_path"
}

print_help() {
    cat >&2 <<'EOF'
Usage: populate_privetelib.sh [options]

Rebuild the app-registered personal library database (privetelib) from
the on-disk Books collection, md5-matching every book file against the
flibusta catalog (mlbook.md5) and representing ONLY the resolved books
in privetelib.  privetelib's own AUTO_INCREMENT columns generate every
key (captured via LAST_INSERT_ID() into session variables that child
rows reference), mlbook.filename/arcname carry the real on-disk paths,
and the reference tables (authors, genres, series) are populated for the
personal library's books only.  flibusta/mllbr_main are never written;
the tool manages only the catalog tables it populates.  See
docs/REPRESENTATION_PLAN.md (Phase 1).

Options:
  -n, --dry-run        walk + resolve + summarize, change nothing
  -d, --debug          verbose diagnostics on stderr
  -h, --help           show this help
  -v, --version        print version and exit

Exit codes: 0 success, 1 operational failure, 2 usage error.

Environment / config (config/populate_privetelib.conf, all overridable):
  POP_LIBRARY_ROOT / POP_REPORT_DIR / POP_SOURCE_DB / POP_TARGET_DB /
  POP_CHUNK; MYSQL_CLIENT, MYSQL_HOST, MYSQL_PORT, MYSQL_USER,
  MYSQL_PASSWORD (MYSQL_PWD only), MYSQL_EXTRA_ARGS,
  MYSQL_CONNECT_TIMEOUT, MARIA_*
EOF
}

# --- arg parsing ------------------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -d|--debug)   DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        -v|--version) echo "bin/populate_privetelib.sh v$SCRIPT_VERSION"; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
    esac
done

# --- validation --------------------------------------------------------------------------
[[ -d "$POP_LIBRARY_ROOT" ]] || die "library root not found: $POP_LIBRARY_ROOT"
[[ "$POP_SOURCE_DB" != "$POP_TARGET_DB" ]] || die "POP_SOURCE_DB and POP_TARGET_DB must differ"
[[ "$POP_CHUNK" =~ ^[0-9]+$ ]] && (( POP_CHUNK > 0 )) || die "POP_CHUNK must be a positive integer"
command -v "$MYSQL_CLIENT" >/dev/null 2>&1 \
    || die "$MYSQL_CLIENT not found; install a mysql/mariadb client or set MYSQL_CLIENT"

# --- lifecycle + dispatch -------------------------------------------------------------------
if ! mariadb_maybe_start; then
    if (( DRY_RUN )); then
        log "warn : MariaDB not reachable; dry-run continues with an empty catalog map (all files would be unmatched)"
        : > "$tmp/map.tsv"
    else
        die "cannot start MariaDB (accept the UAC prompt or run WSL2 elevated, or start the server manually)"
    fi
elif ! db_exists "$POP_TARGET_DB"; then
    die "target database '$POP_TARGET_DB' not found; create it in MultiLib.exe first (Flibusta plugin)"
fi

# map first: without it, resolution is impossible (a real run must have it)
if [[ ! -s "$tmp/map.tsv" ]]; then
    if fetch_md5_map; then
        :
    elif (( DRY_RUN )); then
        log "warn : catalog md5 map unavailable; dry-run continues (all files would be unmatched)"
        : > "$tmp/map.tsv"
    else
        die "md5 map fetch failed; is MariaDB reachable? (see debug output)"
    fi
fi

do_walk
do_resolve

# resolved bookid set (sorted unique)
awk -F'\t' '$4 == "matched" && $3 ~ /^[0-9]+$/ { print $3 }' "$tmp/resolved.tsv" \
    | LC_ALL=C sort -un > "$tmp/bookids.txt"

# summary counters
files_total="$(wc -l < "$tmp/files.tsv" | tr -d ' ')"
matched="$(awk -F'\t' '$4 == "matched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
unmatched="$(awk -F'\t' '$4 == "unmatched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
corrupt="$(awk -F'\t' '$3 == "corrupt" {c++} END {print c+0}' "$tmp/resolved.tsv")"
skipped="$(awk -F'\t' '$3 == "skipped" {c++} END {print c+0}' "$tmp/resolved.tsv")"
bookids="$(wc -l < "$tmp/bookids.txt" | tr -d ' ')"
dupes="$(wc -l < "$tmp/dupes.txt" | tr -d ' ')"

if (( ! DRY_RUN )); then
    generate_rebuild_sql
    if [[ -s "$tmp/rebuild.sql" ]]; then
        log "info : rebuilding $POP_TARGET_DB (fresh keys, $(wc -l < "$tmp/rebuild.sql" | tr -d ' ') SQL lines)"
        run_mysql "${mysql_args[@]}" "$POP_TARGET_DB" < "$tmp/rebuild.sql" \
            || die "rebuild of $POP_TARGET_DB failed"
        rows="$(run_mysql "${mysql_args[@]}" -B --skip-column-names \
            -e "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='$POP_TARGET_DB' AND table_name IN ('mlbook','mlauthor','mlgenre','mlseq','mlrating','mlcustinfo','mlauthorname','mlgenrename','mlseqname') ORDER BY table_name" \
            2>/dev/null || true)"
        debug "target rows: $(echo "$rows" | tr '\n' ' ')"
    fi
else
    log "dry-run: would rebuild $POP_TARGET_DB from $bookids resolved bookid(s) (row-by-row INSERTs, fresh keys)"
fi

do_report

# --- summary on stdout -----------------------------------------------------------------------
printf 'populate summary (source %s -> target %s):\n' "$POP_SOURCE_DB" "$POP_TARGET_DB"
printf '  %-33s %6s\n' 'files scanned'            "$files_total"
printf '  %-33s %6s\n' '  zip-wrapped fb2'        "$(awk -F'\t' '$4=="zip"&&$3!="skipped"{c++}END{print c+0}' "$tmp/files.tsv")"
printf '  %-33s %6s\n' '  loose fb2'              "$(awk -F'\t' '$4=="fb2"{c++}END{print c+0}' "$tmp/files.tsv")"
printf '  %-33s %6s\n' '  skipped (non-book)'     "$skipped"
printf '  %-33s %6s\n' '  corrupt (unreadable)'   "$corrupt"
printf '  %-33s %6s\n' 'matched (bookid resolved)' "$matched"
printf '  %-33s %6s\n' 'unmatched (need fallback)' "$unmatched"
printf '  %-33s %6s\n' 'bookids registered'       "$bookids"
printf '  %-33s %6s\n' 'md5 dupes (lowest kept)'  "$dupes"

exit 0