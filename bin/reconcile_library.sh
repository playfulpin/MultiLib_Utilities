#!/usr/bin/env bash

###############################################################################
# bin/reconcile_library.sh
#
# Version:       1.0.0
# Last updated:  2026-09-03
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Reconciliation report: how well does the on-disk book library match the
#   catalog author scope the library is supposed to cover?
#
#   Two sides are compared at the AUTHOR level:
#     * scope  - the flat author list the merge pipeline was built from
#                (default: data/fixtures/authors_list_from_db.txt; the list
#                is regenerable from the MariaDB catalog via
#                bin/export_authors_from_db.sh)
#     * disk   - the library root (default: /mnt/c/Backup_Go7/Books).  The
#                library may be flat (<letter>/<author>[/series]) OR the
#                nested skeleton the merge pipeline produces
#                (<letter>/<prefix>/.../<author>[/series]); both are handled
#                by recognizing author folders BY NAME: a folder is an author
#                folder iff its basename matches a known author name (scope
#                union catalog), so structural skeleton-prefix dirs are never
#                mistaken for authors and authors at any depth are found.
#
#   Every author is classified:
#     matched        in the scope AND on disk (file count reported)
#     missing        in the scope but NO folder on disk
#     empty          in the scope, folder present, but zero files inside
#     orphan-known   on disk but NOT in the scope; known to the catalog
#                    (mlauthorname.FullName) - e.g. from an earlier scope
#     orphan-unknown on disk, not in the scope, unknown to the catalog
#                    (files under no author folder anywhere)
#
#   When the MariaDB catalog is reachable (default), the mlauthorname
#   snapshot is pulled so each row also carries the catalog book count
#   (TotalCount) next to the on-disk file count; --no-db skips the pull
#   (orphans then classify as unknown, counts show "-").
#   The MariaDB lifecycle is shared with bin/export_authors_from_db.sh via
#   lib/mariadb_lifecycle.sh (auto-start when down, graceful stop on exit
#   when this process started it).
#
#   Output: summary on stdout + one TSV report per run in the report dir
#   (processed_at, author, in_scope, on_disk, catalog_known, catalog_books,
#   disk_files, status).  Read-only against the library.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/reconcile_library.sh [options]
#
#   Options:
#       -l, --library-root DIR   library root to scan
#                                [default: /mnt/c/Backup_Go7/Books]
#       -s, --scope-file FILE    author list the library should cover
#                                [default: data/fixtures/authors_list_from_db.txt]
#       -r, --report-dir DIR     directory for the TSV report
#                                [default: /mnt/c/Backup_Go7/merge-reports]
#           --no-db              skip the mlauthorname snapshot
#       -n, --dry-run            analyze and summarize, write no report file
#       -d, --debug              print verbose diagnostics to stderr
#       -h, --help               show this help
#       -v, --version            print version and exit
#
#   Exit codes:
#       0   success (or --dry-run)
#       1   operational failure
#       2   usage error
#
#   Environment (all optional; also settable in config/reconcile_library.conf):
#       RECON_LIBRARY_ROOT / RECON_SCOPE_FILE / RECON_REPORT_DIR / RECON_DB
#       plus the MYSQL_* and MARIA_* contract from BookTracker-import
#       (defaults in lib/mariadb_lifecycle.sh).
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# --- config file (flag > env > config > built-in default) --------------------
CONF_FILE="${RECON_CONF_FILE:-$PROJECT_ROOT/config/reconcile_library.conf}"
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

RECON_LIBRARY_ROOT="${RECON_LIBRARY_ROOT:-/mnt/c/Backup_Go7/Books}"
RECON_SCOPE_FILE="${RECON_SCOPE_FILE:-$PROJECT_ROOT/data/fixtures/authors_list_from_db.txt}"
RECON_REPORT_DIR="${RECON_REPORT_DIR:-/mnt/c/Backup_Go7/merge-reports}"
RECON_DB="${RECON_DB:-1}"

DRY_RUN=0
DEBUG=0

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
debug() { if (( DEBUG )); then log "debug: $*"; fi; }
die()  { log "error: $*"; exit 1; }

# --- shared MariaDB lifecycle (lib/mariadb_lifecycle.sh) -----------------------
# shellcheck source=../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"

cleanup() {
    [[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"
    mariadb_stop_if_started
    return 0
}
trap cleanup EXIT

print_help() {
    cat >&2 <<'EOF'
Usage: reconcile_library.sh [options]

Compare the on-disk book library against the catalog author scope (the
flat author list the merge pipeline uses, e.g.
data/fixtures/authors_list_from_db.txt) and report, per author:
matched / missing-on-disk / empty / orphan (known or unknown to the
catalog), with catalog book counts vs on-disk file counts.  The library
may be flat (<letter>/<author>[/series]) or the nested skeleton the
merge pipeline produces (<letter>/<prefix>/.../<author>[/series]); a
folder is an author folder when its basename matches a known author
name (scope union catalog), so authors at any depth are found and
structural prefix dirs are ignored.

Options:
  -l, --library-root DIR   library root to scan
                           [default: /mnt/c/Backup_Go7/Books]
  -s, --scope-file FILE    author list the library should cover
                           [default: data/fixtures/authors_list_from_db.txt]
  -r, --report-dir DIR     directory for the TSV report
                           [default: /mnt/c/Backup_Go7/merge-reports]
      --no-db              skip the mlauthorname snapshot
  -n, --dry-run            analyze and summarize, write no report file
  -d, --debug              verbose diagnostics on stderr
  -h, --help               show this help
  -v, --version            print version and exit

Exit codes: 0 success, 1 operational failure, 2 usage error.
EOF
}

# --- arg parsing --------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        -l|--library-root)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; exit 2; }
            RECON_LIBRARY_ROOT="$2"; shift 2 ;;
        --library-root=*) RECON_LIBRARY_ROOT="${1#*=}"; shift ;;
        -s|--scope-file)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; exit 2; }
            RECON_SCOPE_FILE="$2"; shift 2 ;;
        --scope-file=*) RECON_SCOPE_FILE="${1#*=}"; shift ;;
        -r|--report-dir)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; exit 2; }
            RECON_REPORT_DIR="$2"; shift 2 ;;
        --report-dir=*) RECON_REPORT_DIR="${1#*=}"; shift ;;
        --no-db) RECON_DB=0; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -d|--debug)   DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        -v|--version) echo "bin/reconcile_library.sh v$SCRIPT_VERSION"; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
    esac
done

# --- validation ----------------------------------------------------------------
[[ -d "$RECON_LIBRARY_ROOT" ]] || die "library root not found: $RECON_LIBRARY_ROOT"
[[ -f "$RECON_SCOPE_FILE" ]] || die "scope file not found: $RECON_SCOPE_FILE"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/reconcile.XXXXXX")"

# --- 1. scope: normalize the author list (BOM/CR, trim, blanks) ---------------
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/[[:space:]]*$//' "$RECON_SCOPE_FILE" \
    | grep -v '^$' | LC_ALL=C sort -u > "$tmp_dir/scope.txt"
debug "scope: $(wc -l < "$tmp_dir/scope.txt" | tr -d ' ') author(s) from $RECON_SCOPE_FILE"

# --- 2. catalog snapshot (mlauthorname.FullName / TotalCount) ------------------
# Fetched BEFORE the disk walk: the catalog name set tells the disk walk which
# folders are author folders (structural skeleton-prefix dirs share the tree
# with them in the nested layout).
catalog_have=0
: > "$tmp_dir/catalog.txt"
if (( RECON_DB )); then
    if ! command -v "${MYSQL_CLIENT:-mysql}" >/dev/null 2>&1; then
        die "${MYSQL_CLIENT:-mysql} not found; install a mysql/mariadb client or use --no-db"
    fi
    mariadb_maybe_start \
        || die "cannot start MariaDB (accept the UAC prompt or run WSL2 elevated, or start the server manually)"

    mysql_args=("${MYSQL_CLIENT:-mysql}")
    [[ -n "${MYSQL_HOST:-}" ]] && mysql_args+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}" ]] && mysql_args+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}" ]] && mysql_args+=(-u "$MYSQL_USER")
    [[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && mysql_args+=("$MYSQL_EXTRA_ARGS")
    charset="utf8"
    case " ${MYSQL_EXTRA_ARGS:-} " in
        *" --default-character-set="*)
            charset="${MYSQL_EXTRA_ARGS##*--default-character-set=}"
            charset="${charset%% *}" ;;
    esac
    mysql_args+=(--init-command="SET NAMES $charset")
    [[ -n "${MYSQL_DATABASE:-}" ]] && mysql_args+=("$MYSQL_DATABASE")
    mysql_args+=(-B --skip-column-names --raw)

    debug "catalog snapshot: SELECT FullName, TotalCount FROM mlauthorname"
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${mysql_args[@]}" \
            -e "SELECT FullName, TotalCount FROM mlauthorname" > "$tmp_dir/catalog_raw.tsv" 2> "$tmp_dir/catalog_err.txt" || true
    else
        "${mysql_args[@]}" \
            -e "SELECT FullName, TotalCount FROM mlauthorname" > "$tmp_dir/catalog_raw.tsv" 2> "$tmp_dir/catalog_err.txt" || true
    fi
    if [[ ! -s "$tmp_dir/catalog_raw.tsv" ]]; then
        sed 's/^/  /' "$tmp_dir/catalog_err.txt" >&2 || true
        die "mlauthorname snapshot failed; is MariaDB reachable? (rerun with --no-db to skip)"
    fi
    # FullName can repeat (homonyms): keep the highest TotalCount; trim legacy
    # trailing whitespace before using the name as a lookup key.
    awk -F'\t' '{
        sub(/[[:space:]]+$/, "", $1)
        if ($1 == "" || $1 == "NULL") next
        tc = ($2+0 > 0) ? $2+0 : 0
        if (tc > max[$1]) max[$1] = tc
    } END { for (n in max) print n "\t" max[n] }' "$tmp_dir/catalog_raw.tsv" \
        | LC_ALL=C sort -u > "$tmp_dir/catalog.txt"
    catalog_have=1
    debug "catalog snapshot: $(wc -l < "$tmp_dir/catalog.txt" | tr -d ' ') distinct FullName(s)"
fi

# --- 3. disk walk ----------------------------------------------------------------
# desktop.ini is Windows metadata and never counts as a book file.
#
# DB mode (catalog_have=1): the library may be flat (<letter>/<author>[/series])
# or the nested skeleton the merge pipeline produces
# (<letter>/<prefix>/.../<author>[/series]).  The catalog name set tells the
# two apart: a folder is an AUTHOR folder iff its basename matches a known
# author name (scope union catalog); structural prefix dirs never match a
# full author name.  Every FILE is attributed to its NEAREST ancestor author
# folder, so nested prefix dirs never steal files from the author folders
# below them.  Files whose ancestor chain contains no author folder are stray
# content (orphan), attributed to the folder directly holding them.
#
# --no-db mode (catalog_have=0): without the name set a nested skeleton
# cannot be told from series dirs, so the tool assumes the flat layout:
# author folders = dirs directly under a letter dir (depth 2), whole-subtree
# file counts (the historical behavior).
if (( catalog_have )); then
    : > "$tmp_dir/names.txt"
    cat "$tmp_dir/scope.txt" >> "$tmp_dir/names.txt"
    cut -f1 "$tmp_dir/catalog.txt" >> "$tmp_dir/names.txt"
    LC_ALL=C sort -u "$tmp_dir/names.txt" -o "$tmp_dir/names.txt"
    gawk '{ print tolower($0) }' "$tmp_dir/names.txt" \
        | LC_ALL=C sort -u > "$tmp_dir/names_lower.txt"

    find "$RECON_LIBRARY_ROOT" -mindepth 2 -type d \
        | sed "s|^$RECON_LIBRARY_ROOT/||" \
        | LC_ALL=C sort > "$tmp_dir/all_dirs.txt"

    # tag author folders (exact or ASCII-casefold name match) in one pass:
    # hold the name sets in memory instead of grep-ing 200k+ names per dir
    : > "$tmp_dir/author_dirs.txt"
    gawk -v names_f="$tmp_dir/names.txt" -v lower_f="$tmp_dir/names_lower.txt" '
FILENAME == names_f {
    names[$0] = 1
    next
}
FILENAME == lower_f {
    lower[tolower($0)] = 1
    next
}
{
    rel = $0
    base = rel
    sub(/.*\//, "", base)
    if (base in names || tolower(base) in lower) print rel
}
' "$tmp_dir/names.txt" "$tmp_dir/names_lower.txt" "$tmp_dir/all_dirs.txt" > "$tmp_dir/author_dirs.txt"

    declare -A author_set=()
    while IFS= read -r rel; do
        author_set["$rel"]=1
    done < "$tmp_dir/author_dirs.txt"

    # emit one row per author folder (possibly 0 files -> "empty" later)
    : > "$tmp_dir/disk_raw.txt"
    while IFS= read -r rel; do
        printf 'A\t%s\t0\n' "${rel##*/}" >> "$tmp_dir/disk_raw.txt"
    done < "$tmp_dir/author_dirs.txt"

    # nearest-author-ancestor lookup: walk up from the file's parent dir; the
    # deepest ancestor present in author_set wins.
    nearest_author() { # relpath -> author relpath (or empty when none)
        local rel="$1"
        while [[ "$rel" == */* ]]; do
            rel="${rel%/*}"
            if [[ -n "${author_set[$rel]+x}" ]]; then
                echo "$rel"
                return 0
            fi
        done
        return 1
    }

    while IFS= read -r file; do
        rel="${file#"$RECON_LIBRARY_ROOT"/}"
        base="${rel##*/}"
        [[ "$base" == desktop.ini || "$base" == .* ]] && continue
        if owner="$(nearest_author "$rel")"; then
            printf 'A\t%s\t1\n' "${owner##*/}" >> "$tmp_dir/disk_raw.txt"
        else
            # stray: no author folder above it; attribute to the folder that
            # directly holds the file (its parent relpath)
            parent="${rel%/*}"
            printf 'O\t%s\t1\n' "${parent##*/}" >> "$tmp_dir/disk_raw.txt"
        fi
    done < <(find "$RECON_LIBRARY_ROOT" -type f | LC_ALL=C sort)
    unset author_set

    awk -F'\t' '{ sum[$2] += $3 } END { for (n in sum) print n "\t" sum[n] }' \
        "$tmp_dir/disk_raw.txt" | LC_ALL=C sort -u > "$tmp_dir/disk.txt"
else
    # no-DB / flat-layout fallback: author = depth-2 dir under a letter
    : > "$tmp_dir/disk.txt"
    while IFS= read -r dir; do
        name="$(basename "$dir")"
        [[ "$name" == .* ]] && continue
        files="$(find "$dir" -type f ! -iname desktop.ini 2>/dev/null | wc -l | tr -d ' ')"
        printf '%s\t%s\n' "$name" "$files" >> "$tmp_dir/disk.txt"
    done < <(find "$RECON_LIBRARY_ROOT" -mindepth 2 -maxdepth 2 -type d | LC_ALL=C sort)
    LC_ALL=C sort -u "$tmp_dir/disk.txt" -o "$tmp_dir/disk.txt"
fi
debug "disk: $(wc -l < "$tmp_dir/disk.txt" | tr -d ' ') author/orphan folder(s), "\
     "$(awk -F'\t' '{s+=$2} END{print s+0}' "$tmp_dir/disk.txt") file(s)"

# --- 4. classify in a single awk pass -------------------------------------------
# exact byte match first; ASCII-casefold is the fallback (folder names were
# created from the scope list, so case differences mean hand-added folders).
# shellcheck disable=SC2016
gawk -F'\t' -v OFS='\t' -v ts="$(date '+%Y-%m-%d %H:%M:%S')" \
     -v scope_f="$tmp_dir/scope.txt" -v disk_f="$tmp_dir/disk.txt" \
     -v cat_f="$tmp_dir/catalog.txt" -v have_cat="$catalog_have" '
FILENAME == scope_f {
    s[$0] = 1
    sci[tolower($0)] = $0
    next
}
FILENAME == disk_f {
    d[$1] = $2
    dci[tolower($1)] = $1
    next
}
FILENAME == cat_f {
    c[$1] = $2
    cci[tolower($1)] = 1
    next
}
END {
    delete ARGV
    PROCINFO["sorted_in"] = "@ind_str_asc"
    # union of all names to report (scope names + disk folder names)
    for (n in s) u[n] = 1
    for (n in d) u[n] = 1
    for (n in u) {
        in_scope = (n in s) ? 1 : 0
        on_disk  = (n in d) ? 1 : 0
        files    = on_disk ? d[n] : "-"
        # casefold fallback: a disk folder that is a case variant of a scope
        # name, or a scope name whose disk folder is a case variant
        matched_ci = 0
        if (!in_scope && on_disk && (tolower(n) in sci)) matched_ci = 1
        if (in_scope && !on_disk && (tolower(n) in dci)) matched_ci = 1
        known = 0
        books = "-"
        if (have_cat) {
            if (n in c) { known = 1; books = c[n] }
            else if (tolower(n) in cci) known = 1
        }
        if (matched_ci) { status = "matched" }
        else if (in_scope && on_disk && files == 0) { status = "empty" }
        else if (in_scope && on_disk)               { status = "matched" }
        else if (in_scope)                          { status = "missing" }
        else if (known == 1)                        { status = "orphan-known" }
        else                                        { status = "orphan-unknown" }
        cnt[status]++
        print ts "\t" n "\t" in_scope "\t" on_disk "\t" known "\t" books "\t" files "\t" status
    }
    # status counts go to stderr (captured by the shell into summary.txt)
    for (st in cnt) print st, cnt[st] > "/dev/stderr"
}
' "$tmp_dir/scope.txt" "$tmp_dir/disk.txt" "$tmp_dir/catalog.txt" \
    > "$tmp_dir/report.tsv" 2> "$tmp_dir/summary.txt" || die "classification failed"

LC_ALL=C sort -t $'\t' -k8,8 -k2,2 "$tmp_dir/report.tsv" -o "$tmp_dir/report.tsv"

# --- 5. summary + report ---------------------------------------------------------
declare -A counts
while read -r st n; do
    counts[$st]=$n
done < "$tmp_dir/summary.txt"
printf 'reconciliation summary:\n'
printf '  matched          %6s\n'   "${counts[matched]:-0}"
printf '  missing (no folder)   %4s\n' "${counts[missing]:-0}"
printf '  empty (folder, 0 files)%3s\n' "${counts[empty]:-0}"
printf '  orphan-known     %6s\n'  "${counts[orphan-known]:-0}"
printf '  orphan-unknown   %6s\n'  "${counts[orphan-unknown]:-0}"
awk -F'\t' 'NR>1 && $7 != "-" {n+=$7} END{printf "  on-disk files    %6d\n", n}' "$tmp_dir/report.tsv"

report_name="reconcile_library_$(date '+%Y%m%d-%H%M%S').tsv"
if (( DRY_RUN )); then
    log "dry-run: report would be written to $RECON_REPORT_DIR/$report_name"
else
    mkdir -p "$RECON_REPORT_DIR"
    cp "$tmp_dir/report.tsv" "$RECON_REPORT_DIR/$report_name"
    log "info : report written to $RECON_REPORT_DIR/$report_name"
fi
