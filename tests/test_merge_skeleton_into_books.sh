#!/usr/bin/env bash

###############################################################################
# tests/test_merge_skeleton_into_books.sh
#
# Regression suite for bin/merge_skeleton_into_books.sh, the finalize step
# that turns the populated skeleton into the Books library:
#
#     1. rename the skeleton to a timestamped staging folder BooksInput_<ts>;
#     2. remove every empty directory inside the staging folder;
#     3. copy the remaining content into Books, never overwriting anything.
#
# Coverage:
#   * DRY RUN          -- prints the three steps, writes a would-copy report,
#                         and changes nothing.
#   * FULL RUN         -- rename + prune + copy-without-overwrite + retain staging.
#   * NO-RENAME        -- source keeps its name (only prune + copy).
#   * FROM-PRUNED      -- --from-pruned skips rename + prune.
#   * AUTO-DETECT      -- source named BooksInput_* automatically skips rename + prune.
#   * CLI              -- usage errors, -h/-v, staging collision, guards.
#   * VERSION          -- script carries a 0.1.x header version.
#
# Usage:
#   bash tests/test_merge_skeleton_into_books.sh
#
# Runs under both Cygwin/MSYS bash and WSL (no UTF-8 slicing involved).
#
# Exit status: 0 if every check passed, 1 otherwise.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../bin/merge_skeleton_into_books.sh"

[[ -f "$SCRIPT" ]] || { echo "ERROR: $SCRIPT not found" >&2; exit 2; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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

run_script() { # out err -- args...
    local out="$1" err="$2"
    shift 2
    if [[ "${1:-}" == "--" ]]; then shift; fi
    set +e
    bash "$SCRIPT" "$@" > "$out" 2> "$err"
    LAST_RC=$?
    set -e
}

###############################################################################
# fixture: a populated skeleton + a Books library with one conflicting file
###############################################################################
build_fixture() { # base
    local base="$1"
    local sk="$base/Empty_Skeleton" books="$base/Books"

    mkdir -p "$sk/Т/То/Толс/Толстой Лев Николаевич"
    mkdir -p "$sk/С/Сл"
    mkdir -p "$sk/emptyA"
    mkdir -p "$sk/emptyB/inner"

    printf 'fb2\n' > "$sk/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2"
    printf 'SRC\n' > "$sk/С/Сл/Same.fb2"

    mkdir -p "$books/С/Сл"
    printf 'TGT\n' > "$books/С/Сл/Same.fb2"    # pre-existing conflict, wins
    printf 'KEEP\n' > "$books/keep.fb2"
}

# --- locate the single generated report file in REPORT_DIR ------------------
report_for() { # report_dir -> prints the file path (or nothing)
    find "$1" -maxdepth 1 -name 'merge_skeleton_into_books_*.tsv' | head -n 1
}

###############################################################################
# dry run: no changes
###############################################################################
run_dry_tests() {
    echo "== dry run =="
    local base="$TMPDIR/dry" out="$TMPDIR/dry_out.txt" err="$TMPDIR/dry_err.txt"
    local reports="$TMPDIR/dry_reports"
    build_fixture "$base"

    run_script "$out" "$err" -- \
        --source "$base/Empty_Skeleton" --target "$base/Books" \
        --report-dir "$reports" --dry-run

    if (( LAST_RC == 0 )); then
        report "dry_exits_0" ok
    else
        report "dry_exits_0" fail "exit code $LAST_RC"
    fi

    # Source must still be at its original name after a dry run.
    if [[ -d "$base/Empty_Skeleton" ]] \
       && [[ -z "$(find "$base" -maxdepth 1 -name 'BooksInput_*' -print -quit)" ]]; then
        report "dry_source_untouched" ok
    else
        report "dry_source_untouched" fail "dry run renamed or removed the source"
    fi

    if grep -q 'would-copy' "$(report_for "$reports")" 2>/dev/null; then
        report "dry_report_would_copy" ok
    else
        report "dry_report_would_copy" fail "report lacks a would-copy row"
    fi
}

###############################################################################
# full run: rename, prune, copy-without-overwrite, keep staging
###############################################################################
run_full_tests() {
    echo "== full run =="
    local base="$TMPDIR/full" out="$TMPDIR/full_out.txt" err="$TMPDIR/full_err.txt"
    local reports="$TMPDIR/full_reports"
    build_fixture "$base"

    run_script "$out" "$err" -- \
        --source "$base/Empty_Skeleton" --target "$base/Books" \
        --report-dir "$reports"

    if (( LAST_RC == 0 )); then
        report "full_exits_0" ok
    else
        report "full_exits_0" fail "exit code $LAST_RC"
    fi

    # The source skeleton was renamed to BooksInput_<ts>.
    local staging
    staging="$(find "$base" -maxdepth 1 -type d -name 'BooksInput_*' | head -n 1)"
    if [[ -n "$staging" && ! -e "$base/Empty_Skeleton" ]]; then
        report "full_renamed" ok
    else
        report "full_renamed" fail "source not renamed to BooksInput_<ts>"
    fi

    # Empty directories were pruned from the staging folder.
    if [[ -n "$staging" ]] \
       && [[ ! -d "$staging/emptyA" ]] \
       && [[ ! -d "$staging/emptyB" ]] \
       && [[ "$(find "$staging" -type d -empty | wc -l)" == "0" ]]; then
        report "full_empties_pruned" ok
    else
        report "full_empties_pruned" fail "empty directories remain in the staging folder"
    fi

    # Unique content copied into Books, with the conflict left untouched.
    local ok=true
    [[ "$(cat "$base/Books/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2")" == "fb2" ]] || ok=false
    [[ "$(cat "$base/Books/С/Сл/Same.fb2")" == "TGT" ]] || ok=false          # not overwritten
    [[ "$(cat "$base/Books/keep.fb2")" == "KEEP" ]] || ok=false
    if [[ "$ok" == true ]]; then
        report "full_copy_no_overwrite" ok
    else
        report "full_copy_no_overwrite" fail "copy or overwrite behavior wrong"
    fi

    # The staging folder is retained complete with its books.
    if [[ -n "$staging" ]] \
       && [[ -f "$staging/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2" ]] \
       && [[ -f "$staging/С/Сл/Same.fb2" ]]; then
        report "full_staging_retained" ok
    else
        report "full_staging_retained" fail "staging folder was not retained intact"
    fi

    # Report shows the kept-existing conflict.
    local rfile
    rfile="$(report_for "$reports")"
    if [[ -n "$rfile" ]] && grep -q 'kept-existing' "$rfile" \
       && grep -q 'Same.fb2' "$rfile"; then
        report "full_report_kept_existing" ok
    else
        report "full_report_kept_existing" fail "report does not record the kept conflict"
    fi
}

###############################################################################
# no-rename: prune + copy, source keeps its name
###############################################################################
run_no_rename_tests() {
    echo "== --no-rename =="
    local base="$TMPDIR/nr" out="$TMPDIR/nr_out.txt" err="$TMPDIR/nr_err.txt"
    local reports="$TMPDIR/nr_reports"
    build_fixture "$base"

    run_script "$out" "$err" -- \
        --source "$base/Empty_Skeleton" --target "$base/Books" \
        --report-dir "$reports" --no-rename

    if [[ -d "$base/Empty_Skeleton" ]] \
       && [[ "$(cat "$base/Books/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2")" == "fb2" ]]; then
        report "no_rename_kept_and_copied" ok
    else
        report "no_rename_kept_and_copied" fail "no-rename did not keep source or copy content"
    fi
}

###############################################################################
# --from-pruned: skip rename + prune
###############################################################################
run_from_pruned_tests() {
    echo "== --from-pruned =="
    local base="$TMPDIR/fp" out="$TMPDIR/fp_out.txt" err="$TMPDIR/fp_err.txt"
    local reports="$TMPDIR/fp_reports"
    build_fixture "$base"

    # Rename the fixture source to look like a staging folder
    mv "$base/Empty_Skeleton" "$base/BooksInput_test"

    run_script "$out" "$err" -- \
        --source "$base/BooksInput_test" --target "$base/Books" \
        --report-dir "$reports" --from-pruned

    if (( LAST_RC == 0 )); then
        report "from_pruned_exits_0" ok
    else
        report "from_pruned_exits_0" fail "exit code $LAST_RC"
    fi

    # Source must keep its name
    if [[ -d "$base/BooksInput_test" ]]; then
        report "from_pruned_source_kept" ok
    else
        report "from_pruned_source_kept" fail "source was renamed or removed"
    fi

    # Content was copied
    if [[ "$(cat "$base/Books/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2")" == "fb2" ]]; then
        report "from_pruned_copied" ok
    else
        report "from_pruned_copied" fail "content was not copied"
    fi

    # Mode message appears
    if grep -q 'mode: from-pruned' "$out"; then
        report "from_pruned_mode_message" ok
    else
        report "from_pruned_mode_message" fail "expected mode message not found"
    fi
}

###############################################################################
# auto-detect: source named BooksInput_* skips rename + prune
###############################################################################
run_auto_detect_tests() {
    echo "== auto-detect BooksInput_* =="
    local base="$TMPDIR/ad" out="$TMPDIR/ad_out.txt" err="$TMPDIR/ad_err.txt"
    local reports="$TMPDIR/ad_reports"
    build_fixture "$base"

    mv "$base/Empty_Skeleton" "$base/BooksInput_auto"

    run_script "$out" "$err" -- \
        --source "$base/BooksInput_auto" --target "$base/Books" \
        --report-dir "$reports"

    if (( LAST_RC == 0 )); then
        report "auto_detect_exits_0" ok
    else
        report "auto_detect_exits_0" fail "exit code $LAST_RC"
    fi

    # Source must keep its name (no rename)
    if [[ -d "$base/BooksInput_auto" ]]; then
        report "auto_detect_source_kept" ok
    else
        report "auto_detect_source_kept" fail "source was renamed"
    fi

    # Content was copied
    if [[ "$(cat "$base/Books/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2")" == "fb2" ]]; then
        report "auto_detect_copied" ok
    else
        report "auto_detect_copied" fail "content was not copied"
    fi

    # Auto-detect message appears
    if grep -q 'auto-detected BooksInput_\*' "$out" || grep -q 'auto-detected BooksInput_*' "$out"; then
        report "auto_detect_mode_message" ok
    else
        report "auto_detect_mode_message" fail "expected auto-detect message not found"
    fi
}

###############################################################################
# cli: errors and options
###############################################################################
run_cli_tests() {
    echo "== CLI =="
    local out="$TMPDIR/cli_out.txt" err="$TMPDIR/cli_err.txt"
    local sk="$TMPDIR/cli_sk" books="$TMPDIR/cli_books"
    mkdir -p "$sk/f" "$books"

    # -h prints version and exits non-zero (usage exits 1).
    run_script "$out" "$err" -- -h
    if (( LAST_RC != 0 )) && grep -qE 'merge_skeleton_into_books\.sh v[0-9]+\.[0-9]+\.[0-9]+' "$err"; then
        report "cli_help_version" ok
    else
        report "cli_help_version" fail "-h must print the version and exit 1"
    fi

    # -v prints version and exits 0.
    run_script "$out" "$err" -- -v
    if (( LAST_RC == 0 )) && grep -qE 'v[0-9]+\.[0-9]+\.[0-9]+' "$out"; then
        report "cli_version" ok
    else
        report "cli_version" fail "-v must print the version and exit 0"
    fi

    # Collision on the BooksInput_<ts> name is an error.
    local pre="$TMPDIR/pre"
    mkdir -p "$pre/Empty_Skeleton" "$pre/Books" "$pre/BooksInput_test"
    run_script "$out" "$err" -- --source "$pre/Empty_Skeleton" --target "$pre/Books" --timestamp test
    if (( LAST_RC != 0 )); then
        report "cli_staging_collision" ok
    else
        report "cli_staging_collision" fail "expected non-zero exit when staging name exists"
    fi

    local -a ERROR_CASES=(
        "cli_no_args|"
        "cli_unknown_flag|--bogus $sk $books"
        "cli_bad_source|--source /nonexistent --target $books"
        "cli_bad_target|--source $sk --target /nonexistent"
        "cli_target_inside_source|--source $sk --target $sk/sub"
    )
    # Isolate the flag-less "no args" case from the real machine: point the
    # script's environment fallbacks at guaranteed-missing paths so it must
    # fail on validation regardless of what exists under /mnt/c/Backup_Go7
    # (a stray Empty_Skeleton once made this case exit 0 and run a real
    # finalize).  Explicit flags in the other cases override these env vars.
    for c in "${ERROR_CASES[@]}"; do
        IFS='|' read -r label args <<< "$c"
        MERGE_SOURCE_DIR="$TMPDIR/no_such_source" \
        MERGE_TARGET_DIR="$TMPDIR/no_such_target" \
        MERGE_REPORT_DIR="$TMPDIR/cli_reports" \
            run_script "$out" "$err" -- $args
        if (( LAST_RC != 0 )); then
            report "$label" ok
        else
            report "$label" fail "expected non-zero exit"
        fi
    done
}

###############################################################################
# version header
###############################################################################
run_release_tests() {
    echo "== version header =="
    local v
    v="$(sed -n 's/^# Version:[[:space:]]*//p' "$SCRIPT" | head -n 1)"
    if [[ "$v" =~ ^0\.1\.[0-9]+$ ]]; then
        report "version_header" ok
    else
        report "version_header" fail "got '$v', expected ^0\\.1\\.[0-9]+$"
    fi
}

###############################################################################
# dispatch
###############################################################################
case "${1:-all}" in
    all)    run_dry_tests; run_full_tests; run_no_rename_tests
            run_from_pruned_tests; run_auto_detect_tests
            run_cli_tests; run_release_tests ;;
    dry)    run_dry_tests ;;
    full)   run_full_tests ;;
    no-rename) run_no_rename_tests ;;
    from-pruned) run_from_pruned_tests ;;
    auto)   run_auto_detect_tests ;;
    cli)    run_cli_tests ;;
    release) run_release_tests ;;
    --list)
        echo "dry:         steps reported, nothing changed"
        echo "full:        rename + prune + copy-without-overwrite"
        echo "no-rename:   source keeps its name"
        echo "from-pruned: --from-pruned skips rename + prune"
        echo "auto:        BooksInput_* source auto-skips rename + prune"
        echo "cli:         usage errors, -h/-v, staging collision"
        echo "release:     0.1.x version header"
        exit 0
        ;;
    *) echo "Unknown check group '$1'." >&2; exit 1 ;;
esac

echo ""
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All tests passed."