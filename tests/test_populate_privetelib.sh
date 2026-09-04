#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tests/test_populate_privetelib.sh
#
# Regression suite for bin/populate_privetelib.sh (rebuild of the
# app-registered personal library DB from the on-disk Books collection by
# md5-matching against the flibusta catalog).  No real MariaDB is needed:
# the suite installs mock `mysql`, `unzip`, `zcat`, `tasklist` and
# `powershell.exe` earlier in PATH that record their argv and answer the
# catalog queries deterministically.
#
# Asserts the tool's contract:
#   - walk: zip-wrapped FB2 hashed by DECOMPRESSED content (unzip -p with
#     zcat fallback), loose fb2 hashed directly, desktop.ini / non-book
#     files skipped, unreadable zips marked corrupt
#   - map: one read-only (md5, bookid) pull from flibusta.mlbook with the
#     toolchain connection contract (password via MYSQL_PWD only);
#     duplicate md5s resolve to the lowest bookid and are counted
#   - resolve: matched / unmatched attribution
#   - rebuild: TRUNCATE + INSERT ... SELECT for the 9 managed tables
#     (whole reference tables; per-book tables chunked by POP_CHUNK),
#     per-run column-parity check that skips mismatched tables
#   - report: per-run TSV written only outside --dry-run
#   - guards: target DB missing -> exit 1; source == target -> exit 2
#   - MariaDB lifecycle mocks (already running untouched, down -> start /
#     use / stop, no tasklist disables management, --dry-run reports only)
#   - version header stays in sync with `--version` (1.0.x)
#
# Usage:  bash tests/test_populate_privetelib.sh
# Runs anywhere (pure text processing; the mocks avoid any DB dependency).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/bin/populate_privetelib.sh"

PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILURE_LINES=()

report() { # label  ok|fail  [detail]
    local label="$1" status="$2" detail="${3:-}"
    if [[ "$status" == "ok" ]]; then
        echo "  PASS  $label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL  $label"
        [[ -n "$detail" ]] && echo "        $detail"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILURE_LINES+=("$label: $detail")
    fi
}

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/populate_test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

# --- fixture library tree ------------------------------------------------------
LIB="$TMPDIR/Books"
mkdir -p "$LIB/A/Author One/Series X" "$LIB/Б/Автор Два" "$LIB/Broken"
printf 'content-%s' '01-Book One.zip'   > "$LIB/A/Author One/Series X/01-Book One.zip"
printf 'content-%s' '02-Book Two.zip'   > "$LIB/A/Author One/Series X/02-Book Two.zip"
printf 'content-%s' '03-No Match.zip'   > "$LIB/A/Author One/Series X/03-No Match.zip"
printf 'hello fb2 content' > "$LIB/Б/Автор Два/Книга Три.fb2"
printf 'win metadata' > "$LIB/A/Author One/desktop.ini"
printf 'notes' > "$LIB/A/Author One/notes.txt"
printf 'not a zip' > "$LIB/Broken/Corrupt.zip"

zip1_md5="$(printf 'content-%s' '01-Book One.zip' | md5sum | awk '{print $1}')"
zip2_md5="$(printf 'content-%s' '02-Book Two.zip' | md5sum | awk '{print $1}')"
nomatch_md5="$(printf 'content-%s' '03-No Match.zip' | md5sum | awk '{print $1}')"
fb2_md5="$(md5sum "$LIB/Б/Автор Два/Книга Три.fb2" | awk '{print $1}')"

# --- mocks ---------------------------------------------------------------------
MOCK_BIN="$TMPDIR/mockbin"
MOCK_LOG="$TMPDIR/mysql-argv.log"
MOCK_MAP="$TMPDIR/mock-map.tsv"
mkdir -p "$MOCK_BIN"

# catalog map: zip1 is duplicated in the catalog (999 and 111) - lowest wins;
# 0000... exists in the catalog but is not on disk (03-No Match.zip stays unmatched)
printf '%s\t111\n%s\t222\n%s\t333\n%s\t999\n%s\t777\n' \
    "$zip1_md5" "$zip2_md5" "$fb2_md5" "$zip1_md5" "00000000000000000000000000000000" > "$MOCK_MAP"

cat > "$MOCK_BIN/mysql" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'MYSQL %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
args="$*"
if [[ "$args" == *"SHOW DATABASES LIKE"* ]]; then
    if [[ "${MOCK_DB_EXISTS:-privetelib}" == "__none__" ]]; then
        :
    else
        echo "${MOCK_DB_EXISTS:-privetelib}"
    fi
elif [[ "$args" == *"information_schema.COLUMNS"* ]]; then
    table="$(printf '%s' "$args" | sed -n "s/.*TABLE_NAME='\([^']*\)'.*/\1/p")"
    # parity corruption only for the TARGET db, so source vs target mismatch
    if [[ -n "${MOCK_PARITY_BAD:-}" ]] && [[ "$table" == "$MOCK_PARITY_BAD" ]] \
       && [[ "$args" == *"TABLE_SCHEMA='privetelib'"* ]]; then
        echo "DIFFERENT:int"
    else
        echo "${MOCK_PARITY:-bookid:int,title:varchar}"
    fi
elif [[ "$args" == *"SELECT md5, bookid FROM"* ]]; then
    cat "${MOCK_MAP:-/dev/null}"
elif [[ "$args" == *"SELECT table_name, table_rows FROM"* ]]; then
    echo "${MOCK_TABLE_ROWS:-mlbook 3
mlauthor 3}"
else
    echo "Query OK, 0 rows affected"
fi
exit "${MOCK_RC:-0}"
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"

# unzip -p: content derived from the member filename (deterministic per file);
# a member named Corrupt* fails (drives the zcat fallback -> also fails)
cat > "$MOCK_BIN/unzip" <<'UNZIP_EOF'
#!/usr/bin/env bash
case "$*" in
    *Corrupt*) exit 1 ;;
esac
printf 'content-%s' "$(basename "$2")"
UNZIP_EOF
chmod +x "$MOCK_BIN/unzip"

cat > "$MOCK_BIN/zcat" <<'ZCAT_EOF'
#!/usr/bin/env bash
case "$*" in
    *Corrupt*) exit 1 ;;
esac
printf 'zcat-fallback-content'
ZCAT_EOF
chmod +x "$MOCK_BIN/zcat"

cat > "$MOCK_BIN/tasklist" <<'TASKLIST_EOF'
#!/usr/bin/env bash
if [[ "${MARIA_MOCK_RUNNING:-0}" == "1" ]]; then
    printf 'mysqld.exe                   26464 Console                    1    123,456 K\n'
fi
exit 0
TASKLIST_EOF
cat > "$MOCK_BIN/powershell.exe" <<'PS_EOF'
#!/usr/bin/env bash
printf 'PS %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
exit 0
PS_EOF
chmod +x "$MOCK_BIN/tasklist" "$MOCK_BIN/powershell.exe"

REPORT_DIR="$TMPDIR/reports"

run_tool() { # [args...] ; stdout->$OUT, stderr->$ERR ; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    env PATH="$MOCK_BIN:$PATH" \
        MOCK_LOG="$MOCK_LOG" MOCK_MAP="$MOCK_MAP" \
        MOCK_DB_EXISTS="${MOCK_DB_EXISTS:-privetelib}" \
        MOCK_PARITY="${MOCK_PARITY:-bookid:int,title:varchar}" \
        MOCK_PARITY_BAD="${MOCK_PARITY_BAD:-}" \
        MOCK_TABLE_ROWS="${MOCK_TABLE_ROWS:-mlbook 3
mlauthor 3}" \
        MOCK_RC="${MOCK_RC:-0}" \
        MYSQL_PASSWORD="${MOCK_PASSWORD:-}" \
        MARIA_TASKLIST="${MARIA_TASKLIST_OVERRIDE:-$TMPDIR/no-such-tasklist}" \
        MARIA_MOCK_RUNNING="${MARIA_MOCK_RUNNING:-0}" \
        CONF_FILE="$TMPDIR/no-such.conf" \
        POP_LIBRARY_ROOT="$LIB" POP_REPORT_DIR="$REPORT_DIR" \
        POP_SOURCE_DB="${POP_SOURCE_DB:-flibusta}" \
        POP_TARGET_DB="${POP_TARGET_DB:-privetelib}" \
        POP_CHUNK="${POP_CHUNK:-2}" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

echo "== populate_privetelib =="

# --- version / usage -----------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
case "$version" in
    1.0.*) report "version_header" ok "header $version" ;;
    *)     report "version_header" fail "got '$version', expected 1.0.x" ;;
esac

bash "$TOOL" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/populate_privetelib.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$TOOL" --help >"$TMPDIR/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--dry-run" "$TMPDIR/h.txt" && grep -q "privetelib" "$TMPDIR/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail "help must exit 0 and describe the tool"
fi

bash "$TOOL" --bogus >"$TMPDIR/u.txt" 2>&1
if (( $? == 2 )); then
    report "unknown_option_exit2" ok
else
    report "unknown_option_exit2" fail "expected exit 2"
fi

# --- source == target guard ------------------------------------------------------
POP_SOURCE_DB=privetelib POP_TARGET_DB=privetelib POP_LIBRARY_ROOT="$LIB" bash "$TOOL" >"$TMPDIR/g.txt" 2>&1
if (( $? == 1 )) && grep -q "must differ" "$TMPDIR/g.txt"; then
    report "source_target_must_differ" ok
else
    report "source_target_must_differ" fail "got rc=$? stderr=$(head -2 "$TMPDIR/g.txt")"
fi

# --- dry-run: walk + resolve + report, NO database writes -------------------------
rm -f "$MOCK_LOG"; rm -rf "$REPORT_DIR"
MOCK_RC=0 run_tool --dry-run
argv="$(cat "$MOCK_LOG")"
if (( RC == 0 )) \
   && grep -q "matched (bookid resolved)" "$OUT" \
   && grep -q "3" "$OUT" <<<"$(grep 'matched (bookid resolved)' "$OUT")" \
   && grep -q "unmatched (need fallback)" "$OUT" \
   && grep -q "1" "$OUT" <<<"$(grep 'unmatched (need fallback)' "$OUT")" \
   && grep -q "md5 dupes (lowest kept)" "$OUT" \
   && grep -q "1" "$OUT" <<<"$(grep 'md5 dupes (lowest kept)' "$OUT")"; then
    report "dryrun_summary_counts" ok
else
    report "dryrun_summary_counts" fail "rc=$RC out=$(head -12 "$OUT" | tr '\n' '|')"
fi
if (( RC == 0 )) && [[ "$argv" != *"TRUNCATE"* ]] \
   && [[ ! -d "$REPORT_DIR" ]] \
   && grep -q "would be written" "$ERR"; then
    report "dryrun_no_writes" ok
else
    report "dryrun_no_writes" fail "rc=$RC log=$argv dir=${REPORT_DIR:-absent}"
fi
if [[ "$argv" == *"SELECT md5, bookid FROM flibusta.mlbook"* ]] \
   && [[ "$argv" == *"--skip-column-names --raw"* ]] \
   && [[ "$argv" == *"--connect-timeout="* ]]; then
    report "map_query_contract" ok
else
    report "map_query_contract" fail "got: $argv"
fi
if grep -q "corrupt" "$OUT" && grep -q "skipped (non-book)" "$OUT"; then
    report "walk_corrupt_and_skipped" ok
else
    report "walk_corrupt_and_skipped" fail "out=$(grep -E 'corrupt|skipped' "$OUT" | tr '\n' '|')"
fi

# --- password never on the command line ------------------------------------------
rm -f "$MOCK_LOG"
MOCK_RC=0 MOCK_PASSWORD=s3cret run_tool --dry-run
argv="$(cat "$MOCK_LOG")"
if [[ "$argv" == *"s3cret"* ]]; then
    report "password_never_on_cmdline" fail "password leaked into argv"
else
    report "password_never_on_cmdline" ok
fi

# --- real run: truncate + copy the 9 managed tables --------------------------------
rm -f "$MOCK_LOG"; rm -rf "$REPORT_DIR"
MOCK_RC=0 run_tool
argv="$(cat "$MOCK_LOG")"
if (( RC == 0 )); then
    report "run_exit0" ok
else
    report "run_exit0" fail "rc=$RC stderr=$(head -4 "$ERR")"
fi
all9="mlbook mlauthor mlgenre mlseq mlrating mlcustinfo mlauthorname mlgenrename mlseqname"
ok9=1
for t in $all9; do
    if [[ "$argv" != *"TRUNCATE TABLE privetelib.$t"* ]]; then
        ok9=0
        break
    fi
done
if (( ok9 )); then
    report "truncates_all_9" ok
else
    report "truncates_all_9" fail "missing TRUNCATE; log=$(echo "$argv" | grep TRUNCATE | tr '\n' '|')"
fi
if [[ "$argv" == *"INSERT INTO privetelib.mlauthorname SELECT * FROM flibusta.mlauthorname"* ]] \
   && [[ "$argv" != *"INSERT INTO privetelib.mlauthorname SELECT * FROM flibusta.mlauthorname WHERE bookid IN"* ]]; then
    report "whole_table_copy" ok
else
    report "whole_table_copy" fail "log=$(echo "$argv" | grep INSERT | tr '\n' '|')"
fi
if [[ "$argv" == *"INSERT INTO privetelib.mlbook SELECT * FROM flibusta.mlbook WHERE bookid IN (111,222)"* ]] \
   && [[ "$argv" == *"INSERT INTO privetelib.mlbook SELECT * FROM flibusta.mlbook WHERE bookid IN (333)"* ]]; then
    report "per_book_chunking" ok
else
    report "per_book_chunking" fail "log=$(echo "$argv" | grep mlbook | tr '\n' '|')"
fi
if grep -q "bookids registered" "$OUT" && grep -q "3" "$OUT" <<<"$(grep 'bookids registered' "$OUT")"; then
    report "bookids_registered" ok
else
    report "bookids_registered" fail "out=$(grep 'bookids' "$OUT" | tr '\n' '|')"
fi
report_f="$(ls -1 "$REPORT_DIR"/populate_privetelib_*.tsv 2>/dev/null | head -n 1 || true)"
if [[ -n "$report_f" ]] && grep -q "^processed_at" "$report_f" \
   && grep -q "$zip1_md5" "$report_f" \
   && grep -q "$fb2_md5" "$report_f"; then
    report "report_written" ok
else
    report "report_written" fail "file=${report_f:-none}"
fi
if [[ -n "$report_f" ]] && grep -q "111" "$report_f" \
   && ! grep -q "999" "$report_f"; then
    report "dupe_lowest_bookid" ok
else
    report "dupe_lowest_bookid" fail "report=$(head -8 "$report_f" | tr '\n' '|')"
fi

# --- parity mismatch: table skipped with a warning -----------------------------------
rm -f "$MOCK_LOG"; rm -rf "$REPORT_DIR"
MOCK_RC=0 MOCK_PARITY_BAD=mlgenre run_tool
argv="$(cat "$MOCK_LOG")"
if (( RC == 0 )) && grep -q "column mismatch for mlgenre" "$ERR" \
   && [[ "$argv" != *"INSERT INTO privetelib.mlgenre SELECT"* ]]; then
    report "parity_mismatch_skips_table" ok
else
    report "parity_mismatch_skips_table" fail "rc=$RC stderr=$(head -30 "$ERR" | tr '\n' '|') log=$(echo "$argv" | grep mlgenre | tr '\n' '|')"
fi

# --- guard: target DB missing ----------------------------------------------------------
rm -f "$MOCK_LOG"
MOCK_DB_EXISTS=__none__ MOCK_RC=0 run_tool
if (( RC == 1 )) && grep -q "target database 'privetelib' not found" "$ERR"; then
    report "missing_target_db" ok
else
    report "missing_target_db" fail "rc=$RC stderr=$(head -2 "$ERR")"
fi

# --- MariaDB lifecycle -------------------------------------------------------------
echo "== MariaDB lifecycle =="

# 1) server already running -> left untouched
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=1 MOCK_RC=0 run_tool
if (( RC == 0 )) && grep -q "already running" "$ERR" && ! grep -q "stopping MariaDB" "$ERR"; then
    report "lifecycle_already_running_untouched" ok
else
    report "lifecycle_already_running_untouched" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 2) server down -> started (elevated PS), used, stopped gracefully on exit
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_tool
if (( RC == 0 )) \
   && grep -q "starting MariaDB" "$ERR" \
   && grep -q "MariaDB ready" "$ERR" \
   && grep -q "stopping MariaDB (graceful shutdown)" "$ERR" \
   && grep -q "MariaDB stopped" "$ERR" \
   && grep -q "Start-Process" "$MOCK_LOG"; then
    report "lifecycle_start_use_stop" ok
else
    report "lifecycle_start_use_stop" fail "rc=$RC stderr=$(head -4 "$ERR") pslog=$(cat "$MOCK_LOG")"
fi

# 3) no tasklist interop -> management disabled, tool connects directly
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$TMPDIR/no-such-tasklist" MOCK_RC=0 run_tool
if (( RC == 0 )) && grep -q "tasklist not available" "$ERR" && ! grep -q "starting MariaDB" "$ERR"; then
    report "lifecycle_no_tasklist_disables_mgmt" ok
else
    report "lifecycle_no_tasklist_disables_mgmt" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 4) dry-run reports would-start / would-stop, never touches the server
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_tool --dry-run
if (( RC == 0 )) && grep -q "\[dry-run\] would start MariaDB" "$ERR" \
   && grep -q "\[dry-run\] would stop MariaDB" "$ERR" \
   && ! grep -q "Start-Process" "$MOCK_LOG"; then
    report "lifecycle_dryrun_reports_only" ok
else
    report "lifecycle_dryrun_reports_only" fail "rc=$RC stderr=$(head -4 "$ERR") pslog=$(cat "$MOCK_LOG")"
fi

echo ""
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  - %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All tests passed."
exit 0