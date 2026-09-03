#!/usr/bin/env bash

###############################################################################
# bin/export_authors_from_db.sh
#
# Version:       1.0.1
# Last updated:  2026-09-03
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Regenerate the flat author list consumed by the toolchain
#   (data/fixtures/authors_list_from_db.txt) straight from the MariaDB
#   catalog, instead of maintaining a static snapshot by hand.
#
#   The SQL to run defaults to data/sql/qry_authors_4_and_5_all.sql (authors
#   with at least one book rated 4 or 5 and enough books overall); any query
#   that returns one author name per row works.
#
#   Connection settings use the SAME environment contract as the
#   BookTracker-import project (config/config.sh, "MySQL ingestion" section):
#   MYSQL_CLIENT / MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD /
#   MYSQL_DATABASE / MYSQL_EXTRA_ARGS, with the same defaults.  Both projects
#   talk to the same portable MariaDB on the Windows host.  The password is
#   passed via MYSQL_PWD only and never appears on the mysql command line.
#
#   The tool is intentionally read-only against the catalog: it connects with
#   the configured client, runs the query in batch mode, normalizes the rows
#   (BOM/CRLF, trailing whitespace, blank lines, literal NULL rows), and
#   writes the result.  MariaDB lifecycle mirrors bin/booktracker-ingest.sh:
#   if the server is not running it is started (elevated PowerShell) and,
#   because the exporter started it, stopped again on exit (graceful
#   SHUTDOWN with a taskkill fallback); a server that was already running is
#   left untouched.  --dry-run never starts or stops the server.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/export_authors_from_db.sh [options]
#
#   Options:
#       -q, --query-file FILE   SQL file to execute
#                               [default: data/sql/qry_authors_4_and_5_all.sql]
#       -o, --output FILE       write the author list here
#                               [default: data/fixtures/authors_list_from_db.txt]
#                               ('-' writes to stdout)
#       -n, --dry-run           connect, count the authors, and report what
#                               would be written; change nothing
#       -d, --debug             print verbose diagnostics to stderr
#       -h, --help              show this help
#       -v, --version           print version and exit
#
#   Exit codes:
#       0   success (or --dry-run)
#       1   operational failure (client missing, server down, bad query)
#       2   usage error
#
#   Environment (all optional; same contract as BookTracker-import):
#       MYSQL_CLIENT      client binary (default: mysql)
#       MYSQL_HOST        server host (default: 127.0.0.1)
#       MYSQL_PORT        server port (default: 3306)
#       MYSQL_USER        login user (default: root)
#       MYSQL_PASSWORD    login password (default: empty; MYSQL_PWD only)
#       MYSQL_DATABASE    catalog database (default: flibusta)
#       MYSQL_EXTRA_ARGS  extra client option (default: --default-character-set=utf8)
#
#   MariaDB lifecycle (all optional; same defaults as BookTracker-import):
#       MARIA_TASKLIST      tasklist.exe path (default: /mnt/c/Windows/System32/tasklist.exe)
#       MARIA_TASKKILL      taskkill.exe path (default: /mnt/c/Windows/System32/taskkill.exe)
#       MARIA_EXE           mysqld.exe path  (default: C:\mariadb-10.4.7-winx64\bin\mysqld.exe)
#       MARIA_BIN_DIR       mysqld.exe dir   (default: C:\mariadb-10.4.7-winx64\bin)
#       MARIA_START_TIMEOUT seconds to wait for the server (default: 30)
#       MARIA_READY_TIMEOUT seconds per readiness probe (default: 5)
#       MARIA_STOP_TIMEOUT  seconds to wait for graceful shutdown (default: 15)
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# --- defaults (same contract as BookTracker-import config/config.sh) ---------
MYSQL_CLIENT="${MYSQL_CLIENT:-mysql}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_DATABASE="${MYSQL_DATABASE:-flibusta}"
MYSQL_EXTRA_ARGS="${MYSQL_EXTRA_ARGS:---default-character-set=utf8}"

# --- MariaDB lifecycle (same defaults as BookTracker-import config.sh) --------
# The portable MariaDB runs on the Windows host; WSL2 talks to it over TCP.
# When it is not running the exporter starts it (elevated PowerShell, exactly
# like bin/booktracker-ingest.sh) and - because it started it - stops it on
# exit.  A server that was already running is left untouched.
MARIA_TASKLIST="${MARIA_TASKLIST:-/mnt/c/Windows/System32/tasklist.exe}"
MARIA_TASKKILL="${MARIA_TASKKILL:-/mnt/c/Windows/System32/taskkill.exe}"
MARIA_EXE="${MARIA_EXE:-C:\\mariadb-10.4.7-winx64\\bin\\mysqld.exe}"
MARIA_BIN_DIR="${MARIA_BIN_DIR:-C:\\mariadb-10.4.7-winx64\\bin}"
MARIA_START_TIMEOUT="${MARIA_START_TIMEOUT:-30}"
MARIA_READY_TIMEOUT="${MARIA_READY_TIMEOUT:-5}"
MARIA_STOP_TIMEOUT="${MARIA_STOP_TIMEOUT:-15}"
MARIA_MANAGE_OFF=0
_EXPORT_STARTED_MARIADB=0

QUERY_FILE="${QUERY_FILE:-$PROJECT_ROOT/data/sql/qry_authors_4_and_5_all.sql}"
OUTPUT_FILE="${OUTPUT_FILE:-$PROJECT_ROOT/data/fixtures/authors_list_from_db.txt}"
DRY_RUN=0
DEBUG=0

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
debug() { if (( DEBUG )); then log "debug: $*"; fi; }
die()  { log "error: $*"; exit 1; }

# --- MariaDB lifecycle (mirrors BookTracker-import ingest functions) ----------

# Return 0 when mysqld.exe is visible via the Windows tasklist interop.
# When the interop binary is unavailable (e.g. plain Linux), lifecycle
# management is disabled and the exporter simply connects directly.
mariadb_running() {
    local tl="$MARIA_TASKLIST"
    if [[ ! -x "$tl" ]]; then
        log "warn : tasklist not available: $tl"
        MARIA_MANAGE_OFF=1
        return 1
    fi
    if "$tl" | grep -qi 'mysqld\.exe'; then
        return 0
    fi
    return 1
}

# Return 0 when the server actually answers a query.  The elevated
# Start-Process can be slow or the UAC prompt can sit unaccepted, so process
# presence is not enough.  The probe is bounded: under WSL2 mirrored
# networking a connect to an unbound port can hang instead of refusing.
mariadb_ready() {
    local probe_timeout="$MARIA_READY_TIMEOUT"
    local -a cmd=()
    if command -v timeout >/dev/null 2>&1; then
        cmd=(timeout "$probe_timeout")
    fi
    cmd+=("$MYSQL_CLIENT")
    [[ -n "${MYSQL_HOST:-}" ]] && cmd+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}" ]] && cmd+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}" ]] && cmd+=(-u "$MYSQL_USER")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${cmd[@]}" -e "SELECT 1" >/dev/null 2>&1
    else
        "${cmd[@]}" -e "SELECT 1" >/dev/null 2>&1
    fi
}

# Start the portable MariaDB via an elevated PowerShell process.  Sets the
# guard so mariadb_stop knows it was this script that launched the server.
# Returns 1 when the server does not answer within MARIA_START_TIMEOUT.
mariadb_start() {
    local exe="$MARIA_EXE" dir="$MARIA_BIN_DIR" timeout="$MARIA_START_TIMEOUT" deadline
    if (( DRY_RUN )); then
        log "info : [dry-run] would start MariaDB: $exe --console"
        _EXPORT_STARTED_MARIADB=1
        return 0
    fi
    log "info : starting MariaDB (expect an elevated PowerShell window)"
    if ! command -v powershell.exe >/dev/null 2>&1; then
        log "error: powershell.exe not found; cannot start MariaDB (start it manually)"
        return 1
    fi
    if ! powershell.exe -NoProfile -Command \
        "Start-Process '$exe' -ArgumentList '--console' -WorkingDirectory '$dir' -Verb RunAs"; then
        log "error: failed to start MariaDB (Start-Process returned an error)"
        return 1
    fi
    _EXPORT_STARTED_MARIADB=1
    log "info : MariaDB start command issued; waiting for the server to answer..."
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if mariadb_ready; then
            log "info : MariaDB ready"
            return 0
        fi
        sleep 1
    done
    log "error: MariaDB did not become ready within ${timeout}s (accept the UAC prompt or run WSL2 elevated)"
    _EXPORT_STARTED_MARIADB=0
    return 1
}

# Ask the running server to shut down cleanly (flushes MyISAM buffers, so the
# ml* tables are not left marked as crashed by a hard taskkill).
mariadb_shutdown() {
    local -a cmd=("$MYSQL_CLIENT")
    [[ -n "${MYSQL_HOST:-}" ]] && cmd+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}" ]] && cmd+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}" ]] && cmd+=(-u "$MYSQL_USER")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${cmd[@]}" -e "SHUTDOWN" >/dev/null 2>&1
    else
        "${cmd[@]}" -e "SHUTDOWN" >/dev/null 2>&1
    fi
}

# Stop MariaDB when this script launched it (guard set): graceful SHUTDOWN
# first, wait up to MARIA_STOP_TIMEOUT for mysqld to exit, then taskkill /F.
# A no-op otherwise, so it is safe to call from the EXIT trap on every path.
mariadb_stop() {
    if (( MARIA_MANAGE_OFF )) || [[ "$_EXPORT_STARTED_MARIADB" != 1 ]]; then
        return 0
    fi
    if (( DRY_RUN )); then
        log "info : [dry-run] would stop MariaDB"
        _EXPORT_STARTED_MARIADB=0
        return 0
    fi
    log "info : stopping MariaDB (graceful shutdown)"
    local waited=0 timeout="$MARIA_STOP_TIMEOUT" client_pid
    mariadb_shutdown &
    client_pid=$!
    while (( waited < timeout )); do
        sleep 1
        if ! mariadb_running; then
            kill "$client_pid" 2>/dev/null || true
            wait "$client_pid" 2>/dev/null || true
            log "info : MariaDB stopped"
            _EXPORT_STARTED_MARIADB=0
            return 0
        fi
        waited=$((waited + 1))
    done
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
    log "warn : mysqld.exe still running after ${timeout}s; force-killing"
    local tk="$MARIA_TASKKILL"
    if [[ ! -x "$tk" ]]; then
        log "warn : taskkill not available: $tk"
        _EXPORT_STARTED_MARIADB=0
        return 0
    fi
    if "$tk" /F /IM mysqld.exe >/dev/null 2>&1; then
        log "info : MariaDB stopped (forced)"
    else
        log "warn : taskkill may not have stopped MariaDB (already exited?)"
    fi
    _EXPORT_STARTED_MARIADB=0
    return 0
}

# EXIT trap: remove temp files and stop MariaDB only if this script started it.
cleanup() {
    [[ -n "${tmp_out:-}" ]] && rm -f "$tmp_out"
    [[ -n "${tmp_err:-}" ]] && rm -f "$tmp_err"
    [[ -n "${tmp_clean:-}" ]] && rm -f "$tmp_clean"
    mariadb_stop
    return 0
}
trap cleanup EXIT

print_help() {
    cat >&2 <<'EOF'
Usage: export_authors_from_db.sh [options]

Regenerate the flat author list (one name per line) from the MariaDB
catalog by running a query file, e.g. data/sql/qry_authors_4_and_5_all.sql.
Connection settings mirror the BookTracker-import contract (MYSQL_CLIENT,
MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE,
MYSQL_EXTRA_ARGS); the password is passed via MYSQL_PWD only.

MariaDB lifecycle: when the server is not running it is started (elevated
PowerShell, as in bin/booktracker-ingest.sh) and stopped again on exit
(graceful SHUTDOWN); a server that was already running is left untouched.
--dry-run never starts or stops the server (it reports what it would do).

Options:
  -q, --query-file FILE   SQL file to execute
                          [default: data/sql/qry_authors_4_and_5_all.sql]
  -o, --output FILE       write the author list here ('-' = stdout)
                          [default: data/fixtures/authors_list_from_db.txt]
  -n, --dry-run           connect, count the authors, change nothing
  -d, --debug             verbose diagnostics on stderr
  -h, --help              show this help
  -v, --version           print version and exit

Exit codes: 0 success, 1 operational failure, 2 usage error.
EOF
}

# --- arg parsing --------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        -q|--query-file)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; exit 2; }
            QUERY_FILE="$2"; shift 2 ;;
        --query-file=*) QUERY_FILE="${1#*=}"; shift ;;
        -o|--output)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; exit 2; }
            OUTPUT_FILE="$2"; shift 2 ;;
        --output=*) OUTPUT_FILE="${1#*=}"; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -d|--debug)   DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        -v|--version) echo "bin/export_authors_from_db.sh v$SCRIPT_VERSION"; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
    esac
done

# --- validation ----------------------------------------------------------------
[[ -n "${MYSQL_DATABASE:-}" ]] || die "MYSQL_DATABASE is empty (set it, e.g. flibusta)"
[[ -f "$QUERY_FILE" ]] || die "query file not found: $QUERY_FILE"
if ! command -v "${MYSQL_CLIENT:-mysql}" >/dev/null 2>&1; then
    die "${MYSQL_CLIENT:-mysql} not found; install a mysql/mariadb client or set MYSQL_CLIENT"
fi

# --- MariaDB lifecycle: start when down, stop on exit when we started it -------
if (( DRY_RUN )); then
    mariadb_start
elif mariadb_running; then
    log "info : MariaDB already running; leaving it untouched"
else
    if (( MARIA_MANAGE_OFF )); then
        log "info : MariaDB lifecycle management unavailable (no tasklist); connecting directly"
    else
        mariadb_start || die "cannot start MariaDB (accept the UAC prompt or run WSL2 elevated, or start the server manually)"
    fi
fi

# --- build the client argv (password never included) --------------------------
mysql_args=("${MYSQL_CLIENT:-mysql}")
[[ -n "${MYSQL_HOST:-}" ]] && mysql_args+=(-h "$MYSQL_HOST" --protocol=TCP)
[[ -n "${MYSQL_PORT:-}" ]] && mysql_args+=(-P "$MYSQL_PORT")
[[ -n "${MYSQL_USER:-}" ]] && mysql_args+=(-u "$MYSQL_USER")
[[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && mysql_args+=("$MYSQL_EXTRA_ARGS")

# The server may ignore the client's handshake charset (e.g. configured with
# skip-character-set-client-handshake) and transcode results to its own
# default (cp1251), which would corrupt the UTF-8 list.  Pin the session
# charset explicitly: honor --default-character-set from MYSQL_EXTRA_ARGS
# (default: utf8) via --init-command, which the server always applies.
charset="utf8"
case " ${MYSQL_EXTRA_ARGS:-} " in
    *" --default-character-set="*)
        charset="${MYSQL_EXTRA_ARGS##*--default-character-set=}"
        charset="${charset%% *}"
        ;;
esac
mysql_args+=(--init-command="SET NAMES $charset")

[[ -n "${MYSQL_DATABASE:-}" ]] && mysql_args+=("$MYSQL_DATABASE")

# Batch mode: -B tab-separated rows, --skip-column-names, --raw = no escaping.
mysql_args+=(-B --skip-column-names --raw)

debug "mysql argv (password omitted): ${mysql_args[*]}"
debug "query file: $QUERY_FILE"

# --- run the query (stdin = query file with BOM/CRLF normalized) --------------
# Output rows are captured to a temp file so the write is atomic and the row
# count is known before anything is touched.
tmp_out="$(mktemp)"
tmp_err="$(mktemp)"

# The query file lives in Windows/CR format; strip CRs so mysql parses it.
run_rc=0
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' < "$QUERY_FILE" \
    | { if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
            MYSQL_PWD="$MYSQL_PASSWORD" "${mysql_args[@]}" > "$tmp_out" 2> "$tmp_err"
        else
            "${mysql_args[@]}" > "$tmp_out" 2> "$tmp_err"
        fi
      } || run_rc=$?

if (( run_rc != 0 )); then
    log "error: mysql query failed (exit $run_rc)"
    sed 's/^/  /' "$tmp_err" >&2
    die "query failed; is MariaDB running? (start it first)"
fi

if (( DEBUG )); then
    debug "query returned $(wc -l < "$tmp_out" | tr -d ' ') raw row(s)"
fi

# --- normalize rows: BOM, CR, trailing whitespace, blanks, literal NULL --------
# Literal "NULL" rows appear when the SELECT concatenates a NULL name part
# (MariaDB CONCAT returns NULL); such authors carry no usable name, so they
# are counted and dropped rather than polluting the list with a "NULL" entry.
tmp_clean="$(mktemp)"

sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/[[:space:]]*$//' "$tmp_out" \
    | grep -v '^$' \
    > "$tmp_clean" || true

null_count=0
if grep -q -x 'NULL' "$tmp_clean"; then
    null_count="$(grep -c -x 'NULL' "$tmp_clean")"
    log "warn : dropped $null_count NULL row(s) (CONCAT of an empty name part)"
fi
grep -v -x 'NULL' "$tmp_clean" > "$tmp_out" || true   # reuse tmp_out for final rows

author_count="$(wc -l < "$tmp_out" | tr -d ' ')"
[[ -n "$author_count" ]] || author_count=0

# --- write or report -----------------------------------------------------------
if (( DRY_RUN )); then
    if [[ "$OUTPUT_FILE" == "-" ]]; then
        log "dry-run: $author_count author(s) would be written to stdout"
    else
        log "dry-run: $author_count author(s) would be written to $OUTPUT_FILE"
    fi
    exit 0
fi

if [[ "$OUTPUT_FILE" == "-" ]]; then
    cat "$tmp_out"
    log "info : $author_count author(s) written to stdout"
else
    out_dir="$(dirname "$OUTPUT_FILE")"
    [[ -d "$out_dir" ]] || die "output directory does not exist: $out_dir"
    mv "$tmp_out" "$OUTPUT_FILE"
    log "info : $author_count author(s) written to $OUTPUT_FILE"
fi

exit 0
