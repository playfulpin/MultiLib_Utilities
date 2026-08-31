#!/usr/bin/env bash

###############################################################################
# tests/test_merge_books_into_skeleton.sh
#
# Regression suite for bin/merge_books_into_skeleton.sh: copy the files of
# every top-level archive author folder into the deepest matching prefix
# directory of a pre-built skeleton, preserving book-series subfolders and
# never overwriting anything the user has not explicitly allowed.
#
# Coverage:
#   * DRY RUN   -- resolves every author, writes all six reports, creates no
#                 skeleton directories and copies nothing (status would-copy).
#   * FULL RUN  -- mixed extensions (.fb2/.epub/.zip/.txt) land in the right
#                 prefix dirs with content intact; book-series subfolders are
#                 copied recursively; unmatched authors are reported and
#                 left untouched.
#   * DUPLICATE -- a pre-existing destination file is never overwritten
#                 (policy never) and is recorded as duplicate-name.
#   * COLLISION -- two authors mapping to the same prefix dir with the same
#                 book name: first copy wins, second is recorded as collision.
#   * RE-RUN    -- repeating the same merge is idempotent: every file is a
#                 duplicate-name skip and contents stay unchanged.
#   * NO-RECURSIVE -- --no-recursive copies direct files only and records
#                 series subfolders as skipped.
#   * OVERWRITE -- --overwrite=force replaces existing files (status
#                 overwritten); --overwrite=ask with non-interactive stdin
#                 behaves like never.
#   * CONFIG    -- config file supplies source/skeleton/report-dir and
#                 behavior; command-line flags and environment variables
#                 override it.
#   * AMBIGUOUS -- two distinct skeleton paths sharing the longest matching
#                 prefix: nothing is copied, author is reported.
#   * CLI       -- usage errors, -h/-v, missing/unknown options, bad
#                 overwrite policy, missing config file.
#   * VERSION   -- bin and lib carry the same 0.1.x header version.
#
# Usage:
#   bash tests/test_merge_books_into_skeleton.sh
#
# Unlike the UTF-8-slicing suites, this tool compares prefixes BYTE-wise
# (exact for UTF-8), so the suite runs under both Cygwin/MSYS bash and WSL.
#
# IMPORTANT: every invocation passes --config pointing at an empty file so
# the repository's config/merge_books.conf (real user paths) can never leak
# into a test run.  The config group uses its own explicit config file.
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

# Empty config used by every non-config test invocation (see header note).
EMPTY_CONFIG="$TMPDIR/empty.conf"
: > "$EMPTY_CONFIG"

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
# usage: run_merge <outfile> <errfile> [--stdin FILE] -- args...
run_merge() {
    local outfile="$1" errfile="$2"
    shift 2
    local stdin_file=""
    if [[ "${1:-}" == "--stdin" ]]; then
        stdin_file="$2"
        shift 2
    fi
    # A leading "--" separates the helper's own options from the tool's
    # arguments; strip it so it is never forwarded to the tool (where it
    # would end option parsing).
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi
    set +e
    if [[ -n "$stdin_file" ]]; then
        bash "$SCRIPT" "$@" < "$stdin_file" > "$outfile" 2> "$errfile"
    else
        bash "$SCRIPT" "$@" > "$outfile" 2> "$errfile"
    fi
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

    mkdir -p "$source/Толстой Лев Николаевич/Серия Война и мир"
    printf 'fb2\n' > "$source/Толстой Лев Николаевич/Война и мир.fb2"
    printf 'epub\n' > "$source/Толстой Лев Николаевич/Анна Каренина.epub"
    printf 'zip\n'  > "$source/Толстой Лев Николаевич/collection.zip"
    printf 'txt\n'  > "$source/Толстой Лев Николаевич/notes.txt"
    printf 'nested\n' > "$source/Толстой Лев Николаевич/Серия Война и мир/secret.fb2"

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

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
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

    # 5 direct files + 1 series file would-copy, 0 skipped, 1 unmatched.
    local wc sk un
    wc="$(count_status "$reports/merge-manifest.tsv" "would-copy")"
    sk="$(count_status "$reports/merge-manifest.tsv" "skipped")"
    un="$(count_status "$reports/merge-manifest.tsv" "unmatched-author")"
    if (( wc == 6 && sk == 0 && un == 1 )); then
        report "dry_run_statuses" ok
    else
        report "dry_run_statuses" fail "would-copy=$wc skipped=$sk unmatched=$un (expect 6/0/1)"
    fi

    # The series book resolves to its recursive destination path.
    if grep -q "Серия Война и мир/secret.fb2" "$reports/merge-manifest.tsv"; then
        report "dry_run_series_resolved" ok
    else
        report "dry_run_series_resolved" fail "series file missing from manifest"
    fi

    if grep -q "Неизвестный Автор" "$reports/unmatched-authors.tsv"; then
        report "dry_run_unmatched_reported" ok
    else
        report "dry_run_unmatched_reported" fail "unmatched author missing from report"
    fi
}

###############################################################################
# full run: mixed formats + series land in the right prefix dirs
###############################################################################
run_full_run_tests() {
    echo "== full run =="
    local base="$TMPDIR/full" out="$TMPDIR/full_out.txt" err="$TMPDIR/full_err.txt"
    local reports="$TMPDIR/full_reports"
    build_basic_fixtures "$base"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
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

    if [[ "$(cat "$base/skeleton/Т/То/Толс/Серия Война и мир/secret.fb2")" == "nested" ]]; then
        report "full_run_series_copied" ok
    else
        report "full_run_series_copied" fail "series book missing or wrong content"
    fi

    if [[ -f "$base/source/Author/Толстой Лев Николаевич/Война и мир.fb2" \
       && -f "$base/source/Author/Неизвестный Автор/thing.fb2" ]]; then
        report "full_run_source_untouched" ok
    else
        report "full_run_source_untouched" fail "source archive was modified"
    fi

    local copied
    copied="$(count_status "$reports/merge-manifest.tsv" "copied")"
    if (( copied == 6 )); then
        report "full_run_manifest_copied" ok
    else
        report "full_run_manifest_copied" fail "copied=$copied (expect 6)"
    fi
}

###############################################################################
# duplicate: pre-existing destination file is never overwritten (never)
###############################################################################
run_duplicate_tests() {
    echo "== duplicate-name =="
    local base="$TMPDIR/dup" out="$TMPDIR/dup_out.txt" err="$TMPDIR/dup_err.txt"
    local reports="$TMPDIR/dup_reports"
    build_basic_fixtures "$base" "old"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
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

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
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

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$base/source/Author" \
        --skeleton "$base/skeleton" \
        --report-dir "$reports"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$base/source/Author" \
        --skeleton "$base/skeleton" \
        --report-dir "$reports"

    local dn
    dn="$(count_status "$reports/merge-manifest.tsv" "duplicate-name")"
    if (( dn == 6 )); then
        report "rerun_all_duplicate_name" ok
    else
        report "rerun_all_duplicate_name" fail "duplicate-name rows=$dn (expect 6)"
    fi

    if [[ "$(cat "$base/skeleton/Т/То/Толс/Война и мир.fb2")" == "fb2" ]]; then
        report "rerun_contents_unchanged" ok
    else
        report "rerun_contents_unchanged" fail "file content changed on re-run"
    fi
}

###############################################################################
# no-recursive: direct files only, series subfolders skipped
###############################################################################
run_no_recursive_tests() {
    echo "== --no-recursive =="
    local base="$TMPDIR/nr" out="$TMPDIR/nr_out.txt" err="$TMPDIR/nr_err.txt"
    local reports="$TMPDIR/nr_reports"
    build_basic_fixtures "$base"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$base/source/Author" \
        --skeleton "$base/skeleton" \
        --report-dir "$reports" \
        --no-recursive

    if [[ ! -e "$base/skeleton/Т/То/Толс/Серия Война и мир/secret.fb2" ]]; then
        report "no_recursive_series_not_copied" ok
    else
        report "no_recursive_series_not_copied" fail "series book was copied despite --no-recursive"
    fi

    local sk
    sk="$(count_status "$reports/merge-manifest.tsv" "skipped")"
    if (( sk == 1 )) && grep -q "Серия Война и мир" "$reports/skipped-files.tsv"; then
        report "no_recursive_series_skipped" ok
    else
        report "no_recursive_series_skipped" fail "series folder not recorded as skipped (rows=$sk)"
    fi
}

###############################################################################
# overwrite: force replaces, ask (non-interactive) behaves like never
###############################################################################
run_overwrite_tests() {
    echo "== overwrite policy =="

    # --- force --------------------------------------------------------------
    local base="$TMPDIR/owf" out="$TMPDIR/owf_out.txt" err="$TMPDIR/owf_err.txt"
    local reports="$TMPDIR/owf_reports"
    build_basic_fixtures "$base" "old"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$base/source/Author" \
        --skeleton "$base/skeleton" \
        --report-dir "$reports" \
        --overwrite force

    if [[ "$(cat "$base/skeleton/Т/То/Толс/Война и мир.fb2")" == "fb2" ]]; then
        report "overwrite_force_replaces" ok
    else
        report "overwrite_force_replaces" fail "existing file was not replaced"
    fi

    local ow
    ow="$(count_status "$reports/merge-manifest.tsv" "overwritten")"
    if (( ow >= 1 )); then
        report "overwrite_force_recorded" ok
    else
        report "overwrite_force_recorded" fail "no overwritten rows in manifest"
    fi

    # --- ask with non-interactive stdin: behaves like never -------------------
    local base2="$TMPDIR/owa" out2="$TMPDIR/owa_out.txt" err2="$TMPDIR/owa_err.txt"
    local reports2="$TMPDIR/owa_reports"
    build_basic_fixtures "$base2" "old"

    run_merge "$out2" "$err2" --stdin /dev/null -- \
        --config "$EMPTY_CONFIG" \
        --source "$base2/source/Author" \
        --skeleton "$base2/skeleton" \
        --report-dir "$reports2" \
        --overwrite ask

    if [[ "$(cat "$base2/skeleton/Т/То/Толс/Война и мир.fb2")" == "OLD" ]]; then
        report "overwrite_ask_noninteractive_skips" ok
    else
        report "overwrite_ask_noninteractive_skips" fail "non-interactive ask overwrote a file"
    fi

    local dn
    dn="$(count_status "$reports2/merge-manifest.tsv" "duplicate-name")"
    if (( dn >= 1 )); then
        report "overwrite_ask_recorded" ok
    else
        report "overwrite_ask_recorded" fail "non-interactive ask did not record duplicate-name"
    fi
}

###############################################################################
# config: file supplies paths + behavior; flags and env override it
###############################################################################
run_config_tests() {
    echo "== config file =="
    local base="$TMPDIR/cfg" out="$TMPDIR/cfg_out.txt" err="$TMPDIR/cfg_err.txt"
    local cfg="$TMPDIR/cfg.conf"

    # Config-controlled locations and behavior.
    local cfg_source="$base/source/Author" cfg_skeleton="$base/skeleton"
    local cfg_reports="$base/cfg_reports"
    mkdir -p "$cfg_skeleton/Т/То/Толс"
    mkdir -p "$cfg_source/Толстой Лев Николаевич/Серия"
    printf 'fb2\n' > "$cfg_source/Толстой Лев Николаевич/Война и мир.fb2"
    printf 'nested\n' > "$cfg_source/Толстой Лев Николаевич/Серия/том1.fb2"

    cat > "$cfg" <<EOF
MERGE_SOURCE_DIR="$cfg_source"
MERGE_SKELETON_ROOT="$cfg_skeleton"
MERGE_REPORT_DIR="$cfg_reports"
MERGE_RECURSIVE="OFF"
MERGE_OVERWRITE="never"
EOF

    # No path flags: everything comes from the config file.
    run_merge "$out" "$err" -- --config "$cfg"
    if (( LAST_RC == 0 )) \
       && [[ -f "$cfg_skeleton/Т/То/Толс/Война и мир.fb2" ]] \
       && [[ ! -e "$cfg_skeleton/Т/То/Толс/Серия/том1.fb2" ]] \
       && [[ -f "$cfg_reports/merge-manifest.tsv" ]]; then
        report "config_paths_and_behavior" ok
    else
        report "config_paths_and_behavior" fail "config file was not honored (paths or MERGE_RECURSIVE=OFF)"
    fi

    # Flags override the config file.
    local src2="$TMPDIR/cfg_src2" sk2="$TMPDIR/cfg_sk2" rep2="$TMPDIR/cfg_rep2"
    mkdir -p "$sk2/Т/То/Толс"
    mkdir -p "$src2/Толстой Лев Николаевич/Серия"
    printf 'fb2\n' > "$src2/Толстой Лев Николаевич/Война и мир.fb2"
    printf 'nested\n' > "$src2/Толстой Лев Николаевич/Серия/том1.fb2"

    run_merge "$out" "$err" -- \
        --config "$cfg" \
        --source "$src2" --skeleton "$sk2" --report-dir "$rep2" --recursive
    if (( LAST_RC == 0 )) \
       && [[ -f "$sk2/Т/То/Толс/Серия/том1.fb2" ]] \
       && [[ ! -f "$cfg_skeleton/Т/То/Толс/Серия/том1.fb2" ]]; then
        report "config_flags_override" ok
    else
        report "config_flags_override" fail "command-line flags did not override the config file"
    fi

    # Environment variables override the config file.
    local src3="$TMPDIR/cfg_src3"
    mkdir -p "$src3/Толстой Лев Николаевич"
    printf 'env\n' > "$src3/Толстой Лев Николаевич/env.fb2"

    set +e
    MERGE_SOURCE_DIR="$src3" bash "$SCRIPT" \
        --config "$cfg" --skeleton "$sk2" --report-dir "$rep2" \
        > "$out" 2> "$err"
    rc_env=$?
    set -e
    if (( rc_env == 0 )) && [[ -f "$sk2/Т/То/Толс/env.fb2" ]]; then
        report "config_env_overrides" ok
    else
        report "config_env_overrides" fail "environment variable did not override the config file"
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

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
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
    run_merge "$out" "$err" -- -h
    if (( LAST_RC != 0 )) && grep -qE 'merge_books_into_skeleton\.sh v[0-9]+\.[0-9]+\.[0-9]+' "$err"; then
        report "cli_help_version" ok
    else
        report "cli_help_version" fail "-h must print the version to stderr and exit 1"
    fi

    # -v prints the version and exits 0.
    run_merge "$out" "$err" -- -v
    if (( LAST_RC == 0 )) && grep -qE 'v[0-9]+\.[0-9]+\.[0-9]+' "$out"; then
        report "cli_version" ok
    else
        report "cli_version" fail "-v must print the version and exit 0"
    fi

    local -a ERROR_CASES=(
        "cli_no_args|--config $EMPTY_CONFIG"
        "cli_unknown_flag|--config $EMPTY_CONFIG --bogus $source $skeleton"
        "cli_missing_source|--config $EMPTY_CONFIG --skeleton $skeleton"
        "cli_missing_skeleton|--config $EMPTY_CONFIG --source $source"
        "cli_bad_source|--config $EMPTY_CONFIG --source /nonexistent --skeleton $skeleton"
        "cli_bad_skeleton|--config $EMPTY_CONFIG --source $source --skeleton /nonexistent"
        "cli_bad_overwrite|--config $EMPTY_CONFIG --source $source --skeleton $skeleton --overwrite maybe"
        "cli_missing_config|--config /nonexistent.conf --source $source --skeleton $skeleton"
    )
    for c in "${ERROR_CASES[@]}"; do
        IFS='|' read -r label args <<< "$c"
        run_merge "$out" "$err" -- $args
        if (( LAST_RC != 0 )); then
            report "$label" ok
        else
            report "$label" fail "expected non-zero exit"
        fi
    done

    # Combined and isolated option forms both work.
    run_merge "$out" "$err" -- \
        --config="$EMPTY_CONFIG" --source="$source" --skeleton="$skeleton" \
        --report-dir="$TMPDIR/cli_r1" --dry-run
    rc_combined=$LAST_RC
    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" --source "$source" --skeleton "$skeleton" \
        --report-dir "$TMPDIR/cli_r2" --dry-run
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
              run_collision_tests; run_rerun_tests; run_no_recursive_tests
              run_overwrite_tests; run_config_tests; run_ambiguous_tests
              run_cli_tests; run_release_tests ;;
    dry)      run_dry_run_tests ;;
    full)     run_full_run_tests ;;
    duplicate) run_duplicate_tests ;;
    collision) run_collision_tests ;;
    rerun)    run_rerun_tests ;;
    no-recursive) run_no_recursive_tests ;;
    overwrite) run_overwrite_tests ;;
    config)   run_config_tests ;;
    ambiguous) run_ambiguous_tests ;;
    cli)      run_cli_tests ;;
    release)  run_release_tests ;;
    --list)
        echo "dry:        resolve + report only, nothing copied"
        echo "full:       mixed formats + series copied to the right prefix dirs"
        echo "duplicate:  pre-existing destination never overwritten"
        echo "collision:  same destination name from two sources this run"
        echo "rerun:      repeated merge is idempotent"
        echo "no-recursive: direct files only, series subfolders skipped"
        echo "overwrite:  force replaces, ask (non-interactive) behaves like never"
        echo "config:     config file paths + behavior; flags/env override"
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
