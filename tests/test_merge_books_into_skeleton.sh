#!/usr/bin/env bash

###############################################################################
# tests/test_merge_books_into_skeleton.sh
#
# Regression suite for bin/merge_books_into_skeleton.sh: copy the direct
# files of every top-level archive author folder into the deepest matching
# prefix directory of a pre-built skeleton, without ever overwriting.
#
# Coverage:
#   * DRY RUN   -- resolves every author, writes all six reports, creates no
#                 skeleton directories and copies nothing (status would-copy).
#   * FULL RUN  -- mixed extensions (.fb2/.epub/.zip/.txt) land in the right
#                 prefix dirs with content intact; nested folders are skipped;
#                 unmatched authors are reported and left untouched.
#   * DUPLICATE -- a pre-existing destination file is never overwritten and
#                 is recorded as duplicate-name.
#   * COLLISION -- two authors mapping to the same prefix dir with the same
#                 book name: first copy wins, second is recorded as collision.
#   * RE-RUN    -- repeating the same merge is idempotent: every file is a
#                 duplicate-name skip and contents stay unchanged.
#   * AMBIGUOUS -- two distinct skeleton paths sharing the longest matching
#                 prefix: nothing is copied, author is reported.
#   * CLI       -- usage errors, -h/-v, missing/unknown options, and
#                 non-existent source/skeleton directories.
#   * VERSION   -- bin and lib carry the same 0.1.x header version.
#
# Usage:
#   bash tests/test_merge_books_into_skeleton.sh
#
# Unlike the UTF-8-slicing suites, this tool compares prefixes BYTE-wise
# (exact for UTF-8), so the suite runs under both Cygwin/MSYS bash and WSL.
#
# Exit status: 0 if every check passed, 1 otherwise.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../bin/merge_books_into_skeleton.sh"
LIB="$SCRIPT_DIR/../lib/merge_books_functions.sh"

[[ -f "$SCRIPT" ]] || { echo "ERROR: $SCRIPT not found" >&2; exit 2; }
[[ -f "$LIB" ]] || { echo "ERROR: $LIB not found" >&2; exit 2; }

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

# --- run the merge tool, capture stdout and stderr separately ---------------
# usage: run_merge <outfile> <errfile> -- args...
run_merge() {
    local outfile="$1" errfile="$2"
    shift 2
    set +e
    bash "$SCRIPT" "$@" > "$outfile" 2> "$errfile"
    LAST_RC=$?
    set -e
}

# --- report row counts by status ---------------------------------------------
count_status() { # report  status
    awk -F '\t' -v s="$2" 'NR>1 && $5==s {n++} END{print n+0}' "$1"
}
count_rows() { # report
    awk 'NR>1 {n++} END{print n+0}' "$1"
}

###############################################################################
# fixtures: a basic skeleton + source archive (built in TMPDIR)
###############################################################################
# build_basic_fixtures <dir> [precreate_book]
#   dir          - destination root for skeleton/ and source/Author/
#   precreate_book - if "old", a destination file with OLD content is placed
#                    at Т/То/Толс/Война и мир.fb2 before the merge runs
build_basic_fixtures() {
    local base="$1" precreate="${2:-}"
    local skeleton="$base/skeleton" source="$base/source/Author"

    mkdir -p "$skeleton/А/Аб/Абр/Абра"
    mkdir -p "$skeleton/Т/То/Толс"
    mkdir -p "$skeleton/Д/Де"

    mkdir -p "$source/Толстой Лев Николаевич/nested"
    printf 'fb2\n' > "$source/Толстой Лев Николаевич/Война и мир.fb2"
    printf 'epub\n' > "$source/Толстой Лев Николаевич/Анна Каренина.epub"
    printf 'zip\n'  > "$source/Толстой Лев Николаевич/collection.zip"
    printf 'txt\n'  > "$source/Толстой Лев Николаевич/notes.txt"
    printf 'nested\n' > "$source/Толстой Лев Николаевич/nested/secret.fb2"

    mkdir -p "$source/Абрамов Александр Иванович"
    printf 'book\n' > "$source/Абрамов Александр Иванович/Рассказы.fb2"

    mkdir -p "$source/Неизвестный Автор"
    printf 'x\n' > "$source/Неизвестный Автор/thing.fb2"

    if [[ "$precreate" == "old" ]]; then
        printf 'OLD\n' > "$skeleton/Т/То/Толс/Война и мир.fb2"
    fi
}

###############################################################################
# dry run: resolve and report, copy nothing
###############################################################################
run_dry_run_tests() {
    echo "== dry run =="
    local base="$TMPDIR/dry" out="$TMPDIR/dry_out.txt" err="$TMPDIR/dry_err.txt"
    local reports="$TMPDIR/dry_reports"
    build_basic_fixtures "$base"

    run_merge "$out" "$err" \
        --source "$base/source/Author" \
        --skeleton "$base/skeleton" \
        --report-dir "$reports" \
        --dry-run

    if (( LAST_RC == 0 )); then
        report "dry_run_exits_0" ok
    else
        report "dry_run_exits_0" fail "exit code $LAST_RC"
    fi

    # Skeleton untouched: no new directories, no files.
    local dirs_before dirs_after
    dirs_before="$(find "$base/skeleton" -type d | wc -l)"
    dirs_after="$(find "$base/skeleton" -type d | wc -l)"
    if (( dirs_before == dirs_after )) \
       && [[ -z "$(find "$base/skeleton" -type f)" ]]; then
        report "dry_run_copies_nothing" ok
    else
        report "dry_run_copies_nothing" fail "skeleton modified in dry run"
    fi

    if [[ -f "$reports/merge-manifest.tsv" ]]; then
        report "dry_run_manifest_written" ok
    else
        report "dry_run_manifest_written" fail "merge-manifest.tsv missing"
    fi

    # 5 files would-copy, 1 nested folder skipped, 1 unmatched author.
    local wc sk un
    wc="$(count_status "$reports/merge-manifest.tsv" "would-copy")"
    sk="$(count_status "$reports/merge-manifest.tsv" "skipped")"
    un="$(count_status "$reports/merge-manifest.tsv" "unmatched-author")"
    if (( wc == 5 && sk == 1 && un == 1 )); then
        report "dry_run_statuses" ok
    else
        report "dry_run_statuses" fail "would-copy=$wc skipped=$sk unmatched=$un (expect 5/1/1)"
    fi

    if grep -q "Неизвестный Автор" "$reports/unmatched-authors.tsv"; then
        report "dry_run_unmatched_reported" ok
    else
        report "dry_run_unmatched_reported" fail "unmatched author missing from report"
    fi

    # The nested folder itself is the skipped item (its name is recorded,
    # not the book inside it).
    if grep -q "nested" "$reports/skipped-files.tsv" \
       && grep -q "skipped" "$reports/skipped-files.tsv"; then
        report "dry_run_nested_reported" ok
    else
        report "dry_run_nested_reported" fail "nested folder missing from skipped-files"
    fi
}

###############################################################################
# full run: mixed formats land in the right prefix dirs, source untouched
###############################################################################
run_full_run_tests() {
    echo "== full run =="
    local base="$TMPDIR/full" out="$TMPDIR/full_out.txt" err="$TMPDIR/full_err.txt"
    local reports="$TMPDIR/full_reports"
    build_basic_fixtures "$base"

    run_merge "$out" "$err" \
        --source "$base/source/Author" \
        --skeleton "$base/skeleton" \
        --report-dir "$reports"

    if (( LAST_RC == 0 )); then
        report "full_run_exits_0" ok
    else
        report "full_run_exits_0" fail "exit code $LAST_RC"
    fi

    local ok=true
    [[ "$(cat "$base/skeleton/Т/То/Толс/Война и мир.fb2")" == "fb2" ]] || ok=false
    [[ "$(cat "$base/skeleton/Т/То/Толс/Анна Каренина.epub")" == "epub" ]] || ok=false
    [[ "$(cat "$base/skeleton/Т/То/Толс/collection.zip")" == "zip" ]] || ok=false
    [[ "$(cat "$base/skeleton/Т/То/Толс/notes.txt")" == "txt" ]] || ok=false
    [[ "$(cat "$base/skeleton/А/Аб/Абр/Абра/Рассказы.fb2")" == "book" ]] || ok=false
    if [[ "$ok" == true ]]; then
        report "full_run_mixed_formats_copied" ok
    else
        report "full_run_mixed_formats_copied" fail "a copied file is missing or has wrong content"
    fi

    if [[ ! -e "$base/skeleton/Т/То/Толс/secret.fb2" ]]; then
        report "full_run_nested_not_copied" ok
    else
        report "full_run_nested_not_copied" fail "nested folder content was copied"
    fi

    if [[ -f "$base/source/Author/Толстой Лев Николаевич/Война и мир.fb2" \
       && -f "$base/source/Author/Неизвестный Автор/thing.fb2" ]]; then
        report "full_run_source_untouched" ok
    else
        report "full_run_source_untouched" fail "source archive was modified"
    fi

    local copied
    copied="$(count_status "$reports/merge-manifest.tsv" "copied")"
    if (( copied == 5 )); then
        report "full_run_manifest_copied" ok
    else
        report "full_run_manifest_copied" fail "copied=$copied (expect 5)"
    fi
}

###############################################################################
# duplicate: pre-existing destination file is never overwritten
###############################################################################
run_duplicate_tests() {
    echo "== duplicate-name =="
    local base="$TMPDIR/dup" out="$TMPDIR/dup_out.txt" err="$TMPDIR/dup_err.txt"
    local reports="$TMPDIR/dup_reports"
    build_basic_fixtures "$base" "old"

    run_merge "$out" "$err" \
        --source "$base/source/Author" \
        --skeleton "$base/skeleton" \
        --report-dir "$reports"

    if [[ "$(cat "$base/skeleton/Т/То/Толс/Война и мир.fb2")" == "OLD" ]]; then
        report "duplicate_not_overwritten" ok
    else
        report "duplicate_not_overwritten" fail "pre-existing destination file was overwritten"
    fi

    local dn
    dn="$(count_status "$reports/merge-manifest.tsv" "duplicate-name")"
    if (( dn >= 1 )) && grep -q "Война и мир.fb2" "$reports/duplicates.tsv"; then
        report "duplicate_recorded" ok
    else
        report "duplicate_recorded" fail "duplicate-name rows=$dn, file not in duplicates.tsv"
    fi
}

###############################################################################
# collision: two authors -> same prefix dir, same book name
###############################################################################
run_collision_tests() {
    echo "== collision =="
    local base="$TMPDIR/coll" out="$TMPDIR/coll_out.txt" err="$TMPDIR/coll_err.txt"
    local reports="$TMPDIR/coll_reports"
    local skeleton="$base/skeleton" source="$base/source/Author"

    mkdir -p "$skeleton/М/Май"
    mkdir -p "$source/Майоров Иван" "$source/Майорова Ольга"
    printf 'one\n' > "$source/Майоров Иван/same.fb2"
    printf 'two\n' > "$source/Майорова Ольга/same.fb2"

    run_merge "$out" "$err" \
        --source "$source" \
        --skeleton "$skeleton" \
        --report-dir "$reports"

    # Byte order: "И" (0x98) sorts before "О" (0x9E), so Майоров Иван wins.
    if [[ "$(cat "$skeleton/М/Май/same.fb2")" == "one" ]]; then
        report "collision_first_copy_wins" ok
    else
        report "collision_first_copy_wins" fail "first source did not win"
    fi

    local coll
    coll="$(count_status "$reports/merge-manifest.tsv" "collision")"
    if (( coll == 1 )) && grep -q "Майорова Ольга" "$reports/collisions.tsv"; then
        report "collision_recorded" ok
    else
        report "collision_recorded" fail "collision rows=$coll, author missing from collisions.tsv"
    fi
}

###############################################################################
# re-run: same merge again is idempotent
###############################################################################
run_rerun_tests() {
    echo "== re-run =="
    local base="$TMPDIR/rerun" out="$TMPDIR/rerun_out.txt" err="$TMPDIR/rerun_err.txt"
    local reports="$TMPDIR/rerun_reports"
    build_basic_fixtures "$base"

    run_merge "$out" "$err" \
        --source "$base/source/Author" \
        --skeleton "$base/skeleton" \
        --report-dir "$reports"

    run_merge "$out" "$err" \
        --source "$base/source/Author" \
        --skeleton "$base/skeleton" \
        --report-dir "$reports"

    local dn
    dn="$(count_status "$reports/merge-manifest.tsv" "duplicate-name")"
    if (( dn == 5 )); then
        report "rerun_all_duplicate_name" ok
    else
        report "rerun_all_duplicate_name" fail "duplicate-name rows=$dn (expect 5)"
    fi

    if [[ "$(cat "$base/skeleton/Т/То/Толс/Война и мир.fb2")" == "fb2" ]]; then
        report "rerun_contents_unchanged" ok
    else
        report "rerun_contents_unchanged" fail "file content changed on re-run"
    fi
}

###############################################################################
# ambiguous: two skeleton paths share the longest matching prefix
###############################################################################
run_ambiguous_tests() {
    echo "== ambiguous =="
    local base="$TMPDIR/amb" out="$TMPDIR/amb_out.txt" err="$TMPDIR/amb_err.txt"
    local reports="$TMPDIR/amb_reports"
    local skeleton="$base/skeleton" source="$base/source/Author"

    # Both paths represent the prefix "Абра" but are distinct directories.
    mkdir -p "$skeleton/А/Аб/Абр/Абра"
    mkdir -p "$skeleton/Абра"
    mkdir -p "$source/Абрамов Александр"
    printf 'book\n' > "$source/Абрамов Александр/book.fb2"

    run_merge "$out" "$err" \
        --source "$source" \
        --skeleton "$skeleton" \
        --report-dir "$reports"

    if [[ -z "$(find "$skeleton" -name '*.fb2')" ]]; then
        report "ambiguous_copies_nothing" ok
    else
        report "ambiguous_copies_nothing" fail "a file was copied despite the ambiguity"
    fi

    if grep -q "Абрамов" "$reports/ambiguous-authors.tsv"; then
        report "ambiguous_recorded" ok
    else
        report "ambiguous_recorded" fail "author missing from ambiguous-authors.tsv"
    fi
}

###############################################################################
# cli: usage errors and options
###############################################################################
run_cli_tests() {
    echo "== CLI =="
    local out="$TMPDIR/cli_out.txt" err="$TMPDIR/cli_err.txt"
    local skeleton="$TMPDIR/cli_skeleton" source="$TMPDIR/cli_source"
    mkdir -p "$skeleton/Т/То/Толс" "$source/Толстой Лев Николаевич"

    # -h prints the version and exits non-zero (usage() exits 1).
    run_merge "$out" "$err" -h
    if (( LAST_RC != 0 )) && grep -qE 'merge_books_into_skeleton\.sh v[0-9]+\.[0-9]+\.[0-9]+' "$err"; then
        report "cli_help_version" ok
    else
        report "cli_help_version" fail "-h must print the version to stderr and exit 1"
    fi

    # -v prints the version and exits 0.
    run_merge "$out" "$err" -v
    if (( LAST_RC == 0 )) && grep -qE 'v[0-9]+\.[0-9]+\.[0-9]+' "$out"; then
        report "cli_version" ok
    else
        report "cli_version" fail "-v must print the version and exit 0"
    fi

    local -a ERROR_CASES=(
        "cli_no_args|"
        "cli_unknown_flag|--bogus $source $skeleton"
        "cli_missing_source|--skeleton $skeleton"
        "cli_missing_skeleton|--source $source"
        "cli_bad_source|--source /nonexistent --skeleton $skeleton"
        "cli_bad_skeleton|--source $source --skeleton /nonexistent"
    )
    for c in "${ERROR_CASES[@]}"; do
        IFS='|' read -r label args <<< "$c"
        run_merge "$out" "$err" $args
        if (( LAST_RC != 0 )); then
            report "$label" ok
        else
            report "$label" fail "expected non-zero exit"
        fi
    done

    # Combined and isolated option forms both work.
    run_merge "$out" "$err" \
        --source="$source" --skeleton="$skeleton" --report-dir="$TMPDIR/cli_r1" --dry-run
    rc_combined=$LAST_RC
    run_merge "$out" "$err" \
        --source "$source" --skeleton "$skeleton" --report-dir "$TMPDIR/cli_r2" --dry-run
    rc_isolated=$LAST_RC
    if (( rc_combined == 0 && rc_isolated == 0 )) \
       && diff -q "$TMPDIR/cli_r1/merge-manifest.tsv" "$TMPDIR/cli_r2/merge-manifest.tsv" >/dev/null 2>&1; then
        report "cli_forms_identical" ok
    else
        report "cli_forms_identical" fail "combined and isolated option forms differ"
    fi
}

###############################################################################
# version header: bin and lib share the same 0.1.x version
###############################################################################
run_release_tests() {
    echo "== version header =="
    local vbin vlib
    vbin="$(sed -n 's/^# Version:[[:space:]]*//p' "$SCRIPT" | head -n 1)"
    vlib="$(sed -n 's/^# Version:[[:space:]]*//p' "$LIB" | head -n 1)"

    if [[ "$vbin" =~ ^0\.1\.[0-9]+$ ]]; then
        report "version_bin" ok
    else
        report "version_bin" fail "got '$vbin', expected ^0\\.1\\.[0-9]+$"
    fi
    if [[ "$vlib" =~ ^0\.1\.[0-9]+$ ]]; then
        report "version_lib" ok
    else
        report "version_lib" fail "got '$vlib', expected ^0\\.1\\.[0-9]+$"
    fi
    if [[ "$vbin" == "$vlib" ]]; then
        report "version_in_sync" ok
    else
        report "version_in_sync" fail "bin '$vbin' != lib '$vlib'"
    fi
}

###############################################################################
# dispatch
###############################################################################
case "${1:-all}" in
    all)      run_dry_run_tests; run_full_run_tests; run_duplicate_tests
              run_collision_tests; run_rerun_tests; run_ambiguous_tests
              run_cli_tests; run_release_tests ;;
    dry)      run_dry_run_tests ;;
    full)     run_full_run_tests ;;
    duplicate) run_duplicate_tests ;;
    collision) run_collision_tests ;;
    rerun)    run_rerun_tests ;;
    ambiguous) run_ambiguous_tests ;;
    cli)      run_cli_tests ;;
    release)  run_release_tests ;;
    --list)
        echo "dry:        resolve + report only, nothing copied"
        echo "full:       mixed formats copied to the right prefix dirs"
        echo "duplicate:  pre-existing destination never overwritten"
        echo "collision:  same destination name from two sources this run"
        echo "rerun:      repeated merge is idempotent"
        echo "ambiguous:  two skeleton paths share the longest prefix"
        echo "cli:        usage errors, -h/-v, option forms"
        echo "release:    matching 0.1.x version headers"
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
