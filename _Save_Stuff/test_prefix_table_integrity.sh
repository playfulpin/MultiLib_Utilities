#!/usr/bin/env bash

###############################################################################
# test_prefix_table_integrity.sh
#
# Regression suite for prefix_table_integrity.sh.  Builds a synthetic prefix
# table containing one deliberate defect of every kind, then asserts that the
# checker detects each one, returns the right exit status, and honours every
# documented CLI form.
#
# Usage:
#   ./test_prefix_table_integrity.sh          run all checks
#   ./test_prefix_table_integrity.sh --list   list the check groups
#   ./test_prefix_table_integrity.sh severity  run only severity detection
#   ./test_prefix_table_integrity.sh cli       run only CLI-form checks
#
# Exit status: 0 if every check passed, 1 otherwise.
###############################################################################

set -euo pipefail

readonly SCRIPT="$(cd "$(dirname "$0")" && pwd)/prefix_table_integrity.sh"
readonly TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILURES=()

# ---------------------------------------------------------------------------
# run_script <outfile> <args...> -- run the checker, capture stdout+stderr in
# <outfile>, and stash its exit status in $LAST_RC.
# ---------------------------------------------------------------------------
run_script() {
    local outfile="$1"
    shift
    set +e
    "$SCRIPT" "$@" > "$outfile" 2>&1
    LAST_RC=$?
    set -e
}

# ---------------------------------------------------------------------------
# expect_rc <name> <expected_rc> -- assert the last run's exit status.
# ---------------------------------------------------------------------------
expect_rc() {
    local name="$1" expected="$2"
    if (( LAST_RC == expected )); then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS  $name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILURES+=("$name: expected rc=$expected, got rc=$LAST_RC")
        echo "  FAIL  $name (rc=$LAST_RC, expected $expected)"
    fi
}

# ---------------------------------------------------------------------------
# expect_msg <name> <outfile> <pattern> [invert] -- assert a fixed regex
# appears (or, with "invert", does not appear) in the captured output.
# ---------------------------------------------------------------------------
expect_msg() {
    local name="$1" outfile="$2" pattern="$3" invert="${4:-}"
    if [[ "$invert" == "invert" ]]; then
        if ! grep -qE "$pattern" "$outfile"; then
            PASS_COUNT=$((PASS_COUNT + 1))
            echo "  PASS  $name"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILURES+=("$name: pattern '$pattern' unexpectedly present")
            echo "  FAIL  $name (pattern unexpectedly present)"
        fi
    else
        if grep -qE "$pattern" "$outfile"; then
            PASS_COUNT=$((PASS_COUNT + 1))
            echo "  PASS  $name"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILURES+=("$name: pattern '$pattern' not found")
            echo "  FAIL  $name (pattern not found)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Synthetic tables
# ---------------------------------------------------------------------------
# defects.txt exercises every rule.  Order matters: the byte-order check
# compares adjacent rows; duplicate detection needs a repeat.  Byte values:
# АБВ(0x41x) < абв(0x43x) in byte order, and ASCII space (0x20) sorts below
# all Cyrillic, so a handful of rows deliberately break byte order.
cat > "$TMPDIR/defects.txt" <<'EOF'
АБВ	3	1	3
абв	2	4	5
space in prefix	1	6	6
slash/prefix	1	7	7
ПО	1	8	8
	1	9	9
short	abc	10	11
short	1	12	9
short	1	9	abc
badstart	1	x	3
dup	1	13	13
dup	1	14	14
too_long_prefix	1	15	15
plain	2	16	17
malformed	1	2
EOF

# clean.txt has no defects at all (byte-ordered, unique, well-formed).
cat > "$TMPDIR/clean.txt" <<'EOF'
АБВ	3	1	3
абв	2	4	5
пло	1	6	6
EOF

# warnonly.txt has warnings but zero critical problems.
cat > "$TMPDIR/warnonly.txt" <<'EOF'
АБВ	3	1	3
too_long_prefix	1	4	4
a/b	1	5	5
EOF

###############################################################################
# severity: every defect detected, exit statuses, severity filters
###############################################################################
run_severity_tests() {
    echo "== severity detection =="
    local out="$TMPDIR/out_sev.txt"

    # --- Full run over the defect table: rc must be 1 (criticals found) -----
    run_script "$out" "$TMPDIR/defects.txt" 5
    expect_rc defect_table_rc 1

    # --- Every critical defect is named -------------------------------------
    expect_msg crit_malformed     "$out" 'row 15: malformed row \(expected 4 tab-separated columns\)'
    expect_msg crit_empty_prefix  "$out" 'row 6: empty prefix detected'
    expect_msg crit_bad_count     "$out" 'row 7: non-numeric count for prefix \[short\]: abc'
    expect_msg crit_bad_start     "$out" 'row 10: non-numeric start index for prefix \[badstart\]: x'
    expect_msg crit_bad_end       "$out" 'row 9: non-numeric end index for prefix \[short\]: abc'
    expect_msg crit_start_gt_end  "$out" 'row 8: start > end for prefix \[short\]: 12 > 9'
    expect_msg crit_duplicate     "$out" 'row 12: duplicate prefix detected: \[dup\]'

    # --- Every warning defect is named --------------------------------------
    expect_msg warn_space          "$out" 'row 3: space detected in prefix: \[space in prefix\]'
    expect_msg warn_slash          "$out" 'row 4: slash detected in prefix: \[slash/prefix\]'
    expect_msg warn_too_long       "$out" 'row 13: prefix too long \(>5\) \[too_long_prefix\]'
    expect_msg warn_byte_order     "$out" 'rows not in byte order'

    # --- Control character in prefix (raw byte 0x01) ------------------------
    printf 'a\x01b\t1\t20\t20\n' >> "$TMPDIR/defects.txt"
    run_script "$out" "$TMPDIR/defects.txt" 5
    expect_msg warn_control_char "$out" 'row 16: control character detected in prefix'
    head -n -1 "$TMPDIR/defects.txt" > "$TMPDIR/defects.tmp"
    mv "$TMPDIR/defects.tmp" "$TMPDIR/defects.txt"

    # --- Summary line reports the exact totals ------------------------------
    # 15 rows, 9 criticals: empty prefix, bad count, start>end, bad end,
    # bad start, duplicate short (rows 8+9), duplicate dup (row 12),
    # malformed row.
    run_script "$out" "$TMPDIR/defects.txt" 5
    expect_msg summary_counts "$out" 'Checked 15 rows: 9 critical'

    # --- Severity filters ---------------------------------------------------
    run_script "$out" --critical "$TMPDIR/defects.txt" 5
    expect_rc critical_only_rc 1
    expect_msg critical_only_shows_crit "$out" 'row 12: duplicate prefix detected'
    expect_msg critical_only_hides_warn "$out" 'space detected in prefix' invert

    run_script "$out" --warnings "$TMPDIR/defects.txt" 5
    expect_rc warnings_mode_rc 1          # criticals exist -> exit still 1
    expect_msg warnings_mode_shows_warn "$out" 'space detected in prefix'

    run_script "$out" -s warnings "$TMPDIR/warnonly.txt" 5
    expect_rc warnings_only_clean_rc 0    # warnings are non-fatal
    expect_msg warnings_only_shows_warn "$out" 'prefix too long'

    # --- A clean table exits 0 with zero criticals --------------------------
    run_script "$out" "$TMPDIR/clean.txt" 5
    expect_rc clean_table_rc 0
    expect_msg clean_summary "$out" 'Checked 3 rows: 0 critical'
}

###############################################################################
# cli: every documented invocation form
###############################################################################
run_cli_tests() {
    echo "== CLI forms =="
    local out="$TMPDIR/out_cli.txt"

    # Positional, named, and mixed forms must all accept the clean table.
    run_script "$out" "$TMPDIR/clean.txt" 5
    expect_rc cli_positional 0
    run_script "$out" -t "$TMPDIR/clean.txt" -x 5
    expect_rc cli_named 0
    run_script "$out" --table="$TMPDIR/clean.txt" --max-prefix=5
    expect_rc cli_combined_equals 0
    run_script "$out" "$TMPDIR/clean.txt" -x 5
    expect_rc cli_mixed 0
    run_script "$out" -s=info "$TMPDIR/clean.txt" 5
    expect_rc cli_severity_equals 0

    # Errors: unknown flag, missing table/value, bad values, missing file.
    run_script "$out" --bogus "$TMPDIR/clean.txt" 5
    expect_rc cli_unknown_flag 1
    run_script "$out" -x 5
    expect_rc cli_no_table 1
    run_script "$out" -t
    expect_rc cli_missing_value 1
    run_script "$out" -s MAYBE "$TMPDIR/clean.txt" 5
    expect_rc cli_bad_severity 1
    run_script "$out" "$TMPDIR/clean.txt" abc
    expect_rc cli_bad_max 1
    run_script "$out" /nonexistent.txt 5
    expect_rc cli_missing_file 1
    run_script "$out" "$TMPDIR/clean.txt" 5 6
    expect_rc cli_too_many_positional 1

    # Help lists the version.
    run_script "$out" -h
    expect_rc cli_help_rc 1
    expect_msg cli_help_version "$out" 'prefix_table_integrity\.sh v[0-9]+\.[0-9]+\.[0-9]+'
}

###############################################################################
# dispatch
###############################################################################
case "${1:-all}" in
    all)      run_severity_tests; run_cli_tests ;;
    severity) run_severity_tests ;;
    cli)      run_cli_tests ;;
    --list)
        echo "severity: defect_table_rc, crit_*, warn_*, summary_counts, *_filter, clean_table_rc"
        echo "cli:      cli_*"
        exit 0
        ;;
    *) echo "Unknown check group '$1'." >&2; exit 1 ;;
esac

echo ""
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  %s\n' "${FAILURES[@]}"
    exit 1
fi
echo "All tests passed."
