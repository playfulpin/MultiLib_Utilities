#!/usr/bin/env bash

###############################################################################
# bin/populate_privetelib.sh
#
# Version:       1.0.0
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
#       * the tool manages ONLY the pure catalog tables it populates;
#         app-owned tables (mlactual, mldownloaddata, mlnews*, mluser*)
#         are never touched, so rows the app writes itself survive
#       * rebuild semantics: managed tables are cleared and reloaded per
#         run - idempotent by construction, no drift
#
#   Matching is md5-exact (the strongest tier): every book file on disk is
#   hashed (zip-wrapped FB2 by its decompressed content, loose *.fb2
#   directly) and resolved against flibusta.mlbook.md5, which the dump
#   pipeline populates for ALL 869,130 catalog rows.  A single
#   (md5, bookid) map is pulled once and joined locally - no per-file
#   queries.  Files that resolve copy their full catalog rows into
#   privetelib (INSERT ... SELECT by bookid); unmatched files are listed
#   in the per-run report for the author/series/title fallback later.
#
#   Copied tables (column parity verified per run; mismatched tables are
#   skipped with a warning):
#       per-book (WHERE bookid IN (...), chunked):  mlbook, mlauthor,
#           mlgenre, mlseq, mlrating, mlcustinfo
#       whole (small reference tables):             mlauthorname,
#           mlgenrename, mlseqname
#   mlcoverpage / mldescription are NOT populated: the source catalog has
#   them EMPTY (covers/descriptions are not part of the loaded dump;
#   they would need the separate extended-data torrents loaded first).
#
#   After population, switch MultiLib.exe to privetelib to browse the
#   personal collection with ratings/series/genres.  Opening files from
#   inside the app is NOT validated yet (the naming-convention open-trial
#   in the plan); this tool deliberately copies mlbook rows as-is.
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
#       1   operational failure (client missing, server down, no match map)
#       2   usage error
#
#   Environment / config (config/populate_privetelib.conf; all overridable):
#       POP_LIBRARY_ROOT   the personal Books tree (default: /mnt/c/Backup_Go7/Books)
#       POP_REPORT_DIR     where the per-run TSV report goes
#                          (default: /mnt/c/Backup_Go7/merge-reports)
#       POP_SOURCE_DB      read-only catalog DB (default: flibusta)
#       POP_TARGET_DB      the library DB to rebuild (default: privetelib)
#       POP_CHUNK          bookids per INSERT ... SELECT IN-list (default: 500)
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
# *.zip  -> md5 of the DECOMPRESSED content (unzip -p, zcat fallback)
# *.fb2  -> md5 of the file itself
# everything else (desktop.ini, hidden, unknown ext) -> skipped
do_walk() {
    local f rel base ext h
    : > "$tmp/files.tsv"
    while IFS= read -r f; do
        rel="${f#"$POP_LIBRARY_ROOT"/}"
        base="${rel##*/}"
        [[ "$base" == .* ]] && continue
        [[ "${base,,}" == desktop.ini ]] && continue
        case "$base" in
            *.zip|*.ZIP)
                # `|| true` everywhere: set -euo pipefail would otherwise abort
                # the walk when unzip fails on an unreadable zip
                h="$(unzip -p "$f" 2>/dev/null | md5sum | awk '{print $1}' || true)"
                if [[ ! "$h" =~ ^[0-9a-f]{32}$ ]]; then
                    h="$(zcat "$f" 2>/dev/null | md5sum | awk '{print $1}' || true)"
                fi
                if [[ "$h" =~ ^[0-9a-f]{32}$ ]]; then
                    printf '%s\t%s\t%s\tzip\n' "$rel" "$h" "ok" >> "$tmp/files.tsv"
                else
                    printf '%s\t%s\t%s\tzip\n' "$rel" "-" "corrupt" >> "$tmp/files.tsv"
                fi
                ;;
            *.fb2|*.FB2)
                h="$(md5sum "$f" 2>/dev/null | awk '{print $1}' || true)"
                if [[ "$h" =~ ^[0-9a-f]{32}$ ]]; then
                    printf '%s\t%s\t%s\tfb2\n' "$rel" "$h" "ok" >> "$tmp/files.tsv"
                else
                    printf '%s\t%s\t%s\tfb2\n' "$rel" "-" "corrupt" >> "$tmp/files.tsv"
                fi
                ;;
            *)
                printf '%s\t%s\t%s\t%s\n' "$rel" "-" "skipped" "${base##*.}" >> "$tmp/files.tsv"
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
do_resolve() {
    : > "$tmp/resolved.tsv"
    gawk -F'\t' -v map_f="$tmp/map.tsv" '
    FILENAME == map_f { m[$1] = $2; next }
    {
        rel = $1; h = $2; st = $3
        if (st != "ok") { print rel "\t" h "\t-\t" st; next }
        if (h in m) print rel "\t" h "\t" m[h] "\tmatched"
        else        print rel "\t" h "\t-\tunmatched"
    }
    ' "$tmp/map.tsv" "$tmp/files.tsv" | LC_ALL=C sort > "$tmp/resolved.tsv"
    local matched unmatched
    matched="$(awk -F'\t' '$4 == "matched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
    unmatched="$(awk -F'\t' '$4 == "unmatched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
    debug "resolve: $matched file(s) matched, $unmatched unmatched"
}

# --- 4. rebuild the managed catalog tables in the target DB -------------------------
# Per-run column parity check (defensive: the app created privetelib; if a
# table's columns drift from the source, that table is skipped with a warning
# instead of failing the run).
managed_per_book=(mlbook mlauthor mlgenre mlseq mlrating mlcustinfo)
managed_whole=(mlauthorname mlgenrename mlseqname)

rebuild_whole_table() { # table
    local table="$1" fa fb
    fa="$(columns_of "$POP_SOURCE_DB" "$table")"
    fb="$(columns_of "$POP_TARGET_DB" "$table")"
    if [[ -z "$fa" ]] || [[ "$fa" != "$fb" ]]; then
        log "warn : column mismatch for $table (source '$fa' vs target '$fb'); skipping"
        return 0
    fi
    log "info : rebuilding privetelib.$table (whole reference table)"
    if (( DRY_RUN )); then
        log "dry-run: would TRUNCATE privetelib.$table and INSERT ... SELECT * FROM $POP_SOURCE_DB.$table"
        return 0
    fi
    run_mysql "${mysql_args[@]}" -e "TRUNCATE TABLE $POP_TARGET_DB.$table" \
        || die "TRUNCATE $POP_TARGET_DB.$table failed"
    run_mysql "${mysql_args[@]}" -e "INSERT INTO $POP_TARGET_DB.$table SELECT * FROM $POP_SOURCE_DB.$table" \
        || die "copy of $POP_SOURCE_DB.$table into $POP_TARGET_DB failed"
}

rebuild_book_tables() { # bookid list file
    local ids_f="$1" table fa fb i inlist chunk
    mapfile -t BIDS < "$ids_f"
    if (( ${#BIDS[@]} == 0 )); then
        log "warn : no resolved bookids; nothing to copy into $POP_TARGET_DB"
        return 0
    fi
    for table in "${managed_per_book[@]}"; do
        fa="$(columns_of "$POP_SOURCE_DB" "$table")"
        fb="$(columns_of "$POP_TARGET_DB" "$table")"
        if [[ -z "$fa" ]] || [[ "$fa" != "$fb" ]]; then
            log "warn : column mismatch for $table (source '$fa' vs target '$fb'); skipping"
            continue
        fi
        log "info : rebuilding privetelib.$table (${#BIDS[@]} bookid(s), chunks of $POP_CHUNK)"
        if (( DRY_RUN )); then
            log "dry-run: would TRUNCATE privetelib.$table and INSERT ... SELECT * FROM $POP_SOURCE_DB.$table WHERE bookid IN (...)"
            continue
        fi
        run_mysql "${mysql_args[@]}" -e "TRUNCATE TABLE $POP_TARGET_DB.$table" \
            || die "TRUNCATE $POP_TARGET_DB.$table failed"
        for (( i = 0; i < ${#BIDS[@]}; i += POP_CHUNK )); do
            chunk=("${BIDS[@]:i:POP_CHUNK}")
            inlist="$(IFS=,; echo "${chunk[*]}")"
            run_mysql "${mysql_args[@]}" -e \
                "INSERT INTO $POP_TARGET_DB.$table SELECT * FROM $POP_SOURCE_DB.$table WHERE bookid IN ($inlist)" \
                || die "copy of $POP_SOURCE_DB.$table chunk $((i / POP_CHUNK + 1)) failed"
        done
    done
}

# --- 5. per-run report + summary ------------------------------------------------------
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
flibusta catalog (mlbook.md5) and copying the full catalog rows for the
resolved bookids into privetelib.  flibusta/mllbr_main are never
written; the tool manages only the catalog tables it populates.  See
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

rebuild_whole_table mlauthorname
rebuild_whole_table mlgenrename
rebuild_whole_table mlseqname
rebuild_book_tables "$tmp/bookids.txt"

if (( ! DRY_RUN )) && (( bookids > 0 )); then
    # MyISAM table_rows is engine-accurate; one metadata query for the summary
    rows="$(run_mysql "${mysql_args[@]}" -B --skip-column-names \
        -e "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='$POP_TARGET_DB' AND table_name IN ('mlbook','mlauthor','mlgenre','mlseq','mlrating','mlcustinfo','mlauthorname','mlgenrename','mlseqname') ORDER BY table_name" \
        2>/dev/null || true)"
    debug "target rows: $(echo "$rows" | tr '\n' ' ')"
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