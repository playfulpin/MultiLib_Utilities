#!/usr/bin/env bash

###############################################################################
# lib/merge_books_functions.sh
#
# Version:       0.1.0
# Last updated:  2026-08-30 19:55
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Shared functions for bin/merge_books_into_skeleton.sh: copy the direct
#   files of every top-level author folder in a source archive into the
#   deepest valid prefix directory of a pre-built author skeleton, without
#   ever overwriting an existing file.
#
#   The skeleton is the source of truth for destination paths.  It is built
#   beforehand with bin/build_shell_nested_authors.sh, e.g.:
#
#       А/Аб/Абр/Абра        <- deepest valid prefix for "Абрамов ..."
#       Т/То/Толс            <- deepest valid prefix for "Толстой ..."
#
#   An archive author is resolved to the LONGEST skeleton prefix that is a
#   prefix of the author name.  If two different skeleton paths share that
#   longest prefix, the author is reported as ambiguous and nothing is
#   copied.  If no prefix matches, the author is reported as unmatched.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   Sourced by bin/merge_books_into_skeleton.sh; not meant to be executed
#   directly.  All configuration is carried in module-level globals set by
#   merge_parse_args:
#
#       SOURCE_DIR      top-level author folders (one level only)
#       SKELETON_ROOT   pre-built prefix skeleton (never modified)
#       REPORT_DIR      where the TSV reports are written
#       DRY_RUN         true => resolve and report, copy nothing
#
# -----------------------------------------------------------------------------
# ALGORITHM
# -----------------------------------------------------------------------------
#   1. COLLECT the skeleton: every directory becomes "rel<TAB>prefix",
#      where prefix is the LAST path component.  For builder skeletons the
#      components are incremental prefixes, so the last component IS the
#      full author prefix the chain represents ("А/Аб/Абр/Абра" -> "Абра").
#
#   2. RESOLVE each archive author folder to the longest skeleton prefix
#      that is a byte-prefix of the author name.  UTF-8 is self-
#      synchronizing, so byte-prefix comparison is character-exact in both
#      byte-based (Cygwin) and multibyte (WSL) bash.  A builder skeleton
#      always yields exactly one chain per author; several distinct paths
#      sharing the longest prefix are treated as ambiguous.
#
#   3. COPY each direct file into <skeleton>/<rel>/<filename> unless a file
#      with that name already exists.  Nested source folders and non-regular
#      files are skipped.  Every outcome is recorded once in the manifest
#      and once in the specialised report file.
#
#   Prefix matching is deliberately case-sensitive, matching the skeleton
#   builder's LC_ALL=C byte-order semantics: "Толстой" and "толстой" live
#   in different branches of the skeleton.
#
###############################################################################

set -euo pipefail

# --- module state (filled by merge_parse_args) -------------------------------
SOURCE_DIR=""
SKELETON_ROOT=""
REPORT_DIR=""
DRY_RUN=false

# --- report paths (set by merge_prepare_reports) -----------------------------
MANIFEST=""
UNMATCHED_AUTHORS=""
AMBIGUOUS_AUTHORS=""
COLLISIONS=""
DUPLICATES=""
SKIPPED_FILES=""
PROCESSED_AT=""

# --- run-time state ----------------------------------------------------------
declare -a SKEL_DIRS=()        # "rel<TAB>prefix" rows of every skeleton dir
declare -A DEST_SOURCE=()      # dest file -> source file that wrote it this run
MATCH_DEST=""                  # resolved destination (relative to skeleton)
MATCH_AMBIGUOUS=false

# -----------------------------------------------------------------------------
# merge_sanitize
# -----------------------------------------------------------------------------
# Replace tabs and newlines with spaces so one report row always stays one
# line of TSV.  Author names and book names may legitimately contain odd
# characters on disk, but never a literal newline inside a row.
# -----------------------------------------------------------------------------
merge_sanitize() {
    local value="$1"
    value="${value//$'\t'/ }"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    printf '%s' "$value"
}

# -----------------------------------------------------------------------------
# merge_usage
# -----------------------------------------------------------------------------
# Print the command-line contract to standard error and exit 1 (repo
# convention: usage() always exits non-zero, including for -h).
# -----------------------------------------------------------------------------
merge_usage() {
    local version
    version="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"
    echo "bin/merge_books_into_skeleton.sh v$version" >&2
    echo "" >&2
    echo "Usage: $0 --source=DIR --skeleton=DIR [OPTIONS]" >&2
    echo "" >&2
    echo "Required:" >&2
    echo "  -s, --source=DIR      Archive root whose top-level folders are authors" >&2
    echo "  -k, --skeleton=DIR    Pre-built prefix skeleton (source of truth)" >&2
    echo "" >&2
    echo "Optional:" >&2
    echo "  -r, --report-dir=DIR  Where the TSV reports are written" >&2
    echo "                        [default: \$PWD/merge-reports]" >&2
    echo "      --dry-run         Resolve and report only; copy nothing" >&2
    echo "  -v, --version         Print the version and exit 0" >&2
    echo "  -h, --help            Show this help message" >&2
}

# -----------------------------------------------------------------------------
# merge_parse_args
# -----------------------------------------------------------------------------
# Accept named options in combined (-s=DIR), isolated (-s DIR), or spaced
# (-s = DIR) forms; "--" ends option parsing.  Unknown options fail loudly.
# -----------------------------------------------------------------------------
merge_parse_args() {
    local arg flag value
    local -a positional=()

    while (( $# > 0 )); do
        arg="$1"

        case "$arg" in
            -h|--help)
                merge_usage
                exit 1
                ;;
            -v|--version)
                echo "merge_books_into_skeleton.sh v$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"
                exit 0
                ;;
            -s=*|--source=*|-k=*|--skeleton=*|-r=*|--report-dir=*)
                flag="${arg%%=*}"
                value="${arg#*=}"
                if [[ -z "$value" ]]; then
                    echo "Error: $flag requires a value." >&2
                    exit 1
                fi
                case "$flag" in
                    -s|--source)      SOURCE_DIR="$value" ;;
                    -k|--skeleton)    SKELETON_ROOT="$value" ;;
                    -r|--report-dir)  REPORT_DIR="$value" ;;
                esac
                ;;
            -s|--source|-k|--skeleton|-r|--report-dir)
                if (( $# < 2 )); then
                    echo "Error: $arg requires a value." >&2
                    exit 1
                fi
                value="$2"
                if [[ "$value" == "=" ]]; then
                    if (( $# < 3 )); then
                        echo "Error: $arg requires a value." >&2
                        exit 1
                    fi
                    value="$3"
                    shift
                elif [[ "$value" == =* ]]; then
                    value="${value#=}"
                fi
                case "$arg" in
                    -s|--source)      SOURCE_DIR="$value" ;;
                    -k|--skeleton)    SKELETON_ROOT="$value" ;;
                    -r|--report-dir)  REPORT_DIR="$value" ;;
                esac
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --)
                shift
                positional+=("$@")
                break
                ;;
            -*)
                echo "Error: Unexpected option or argument '$arg'." >&2
                merge_usage
                exit 1
                ;;
            *)
                positional+=("$arg")
                ;;
        esac

        shift
    done

    # Positional arguments fill the slots in canonical order
    # (source, then skeleton), never overriding a named option.
    if [[ -z "$SOURCE_DIR" ]] && (( ${#positional[@]} > 0 )); then
        SOURCE_DIR="${positional[0]}"
        positional=("${positional[@]:1}")
    fi
    if [[ -z "$SKELETON_ROOT" ]] && (( ${#positional[@]} > 0 )); then
        SKELETON_ROOT="${positional[0]}"
        positional=("${positional[@]:1}")
    fi
    if (( ${#positional[@]} > 0 )); then
        echo "Error: Too many positional arguments." >&2
        merge_usage
        exit 1
    fi

    [[ -n "$REPORT_DIR" ]] || REPORT_DIR="$PWD/merge-reports"
}

# -----------------------------------------------------------------------------
# merge_collect_skeleton_dirs
# -----------------------------------------------------------------------------
# Walk SKELETON_ROOT and store every subdirectory as "rel<TAB>prefix" in
# SKEL_DIRS.  The root itself is excluded: an empty skeleton must leave
# every author unmatched, not route everything into the root.
# -----------------------------------------------------------------------------
merge_collect_skeleton_dirs() {
    local dir rel prefix
    SKEL_DIRS=()

    while IFS= read -r dir; do
        rel="${dir#"$SKELETON_ROOT"/}"
        prefix="${rel##*/}"
        SKEL_DIRS+=("$rel"$'\t'"$prefix")
    done < <(find "$SKELETON_ROOT" -mindepth 1 -type d | LC_ALL=C sort)
}

# -----------------------------------------------------------------------------
# merge_find_dest
# -----------------------------------------------------------------------------
# Resolve an archive author name to the deepest matching skeleton directory.
#
# Arguments:
#   $1 - the author name
#
# Sets:
#   MATCH_DEST        relative destination path ("" on failure)
#   MATCH_AMBIGUOUS   true when several distinct paths share the longest match
#
# Returns 0 when a unique destination was found, 1 when unmatched or
# ambiguous (the caller distinguishes them via MATCH_AMBIGUOUS).
# -----------------------------------------------------------------------------
merge_find_dest() {
    local author="$1"
    local -a matched=()
    local entry rel prefix len maxlen=0

    for entry in "${SKEL_DIRS[@]}"; do
        rel="${entry%%$'\t'*}"
        prefix="${entry#*$'\t'}"
        # Byte-prefix comparison: exact for UTF-8 in byte- and multibyte bash.
        if [[ "${author:0:${#prefix}}" == "$prefix" ]]; then
            len=${#prefix}
            if (( len > maxlen )); then
                maxlen=$len
                matched=("$rel")
            elif (( len == maxlen )); then
                matched+=("$rel")
            fi
        fi
    done

    if (( maxlen == 0 )); then
        MATCH_DEST=""
        MATCH_AMBIGUOUS=false
        return 1
    fi

    # Collapse duplicate paths (same dir found once per entry); more than
    # one DISTINCT path at the longest length is an ambiguous match.
    local -A seen=()
    local -a distinct=()
    for rel in "${matched[@]}"; do
        if [[ -z "${seen[$rel]:-}" ]]; then
            seen[$rel]=1
            distinct+=("$rel")
        fi
    done

    if (( ${#distinct[@]} > 1 )); then
        MATCH_DEST=""
        MATCH_AMBIGUOUS=true
        return 1
    fi

    MATCH_DEST="${distinct[0]}"
    MATCH_AMBIGUOUS=false
    return 0
}

# -----------------------------------------------------------------------------
# merge_record
# -----------------------------------------------------------------------------
# Write one outcome row to the manifest and to the specialised report(s).
#
# Arguments:
#   $1 - status: copied|would-copy|duplicate|duplicate-name|collision|
#                unmatched-author|ambiguous-author|skipped
#   $2 - human-readable reason
#   $3 - source author name
#   $4 - source file name (or "-")
#   $5 - destination path relative to the skeleton (or "-")
# -----------------------------------------------------------------------------
merge_record() {
    local status="$1" reason="$2" author="$3" src="$4" dest="$5"
    local row
    row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
        "$(merge_sanitize "$PROCESSED_AT")" \
        "$(merge_sanitize "$author")" \
        "$(merge_sanitize "$src")" \
        "$(merge_sanitize "$dest")" \
        "$status" \
        "$(merge_sanitize "$reason")")"

    printf '%s\n' "$row" >> "$MANIFEST"

    case "$status" in
        copied|would-copy) ;;
        *) printf '%s\n' "$row" >> "$SKIPPED_FILES" ;;
    esac

    case "$status" in
        unmatched-author) printf '%s\n' "$row" >> "$UNMATCHED_AUTHORS" ;;
        ambiguous-author) printf '%s\n' "$row" >> "$AMBIGUOUS_AUTHORS" ;;
        duplicate|duplicate-name) printf '%s\n' "$row" >> "$DUPLICATES" ;;
        collision) printf '%s\n' "$row" >> "$COLLISIONS" ;;
    esac
}

# -----------------------------------------------------------------------------
# merge_process_author
# -----------------------------------------------------------------------------
# Resolve one top-level source author folder and process its direct children:
# regular files are copy candidates, directories are recorded as skipped
# (nested folders are out of scope for the first implementation).
# -----------------------------------------------------------------------------
merge_process_author() {
    local author_dir="$1"
    local author="${author_dir##*/}"
    local child name target

    # Trim surrounding whitespace from the folder name for lookup/reporting.
    author="${author#"${author%%[![:space:]]*}"}"
    author="${author%"${author##*[![:space:]]}"}"

    if [[ -z "$author" ]]; then
        return
    fi

    if merge_find_dest "$author"; then
        local dest_dir="$SKELETON_ROOT/$MATCH_DEST"
    else
        local status="unmatched-author"
        local reason="no skeleton prefix matches the author name"
        if [[ "$MATCH_AMBIGUOUS" == true ]]; then
            status="ambiguous-author"
            reason="several skeleton paths share the longest matching prefix"
        fi
        # Record every direct child so the manifest is complete, but copy
        # nothing.  An empty author folder records a single author-level row.
        local -a children=()
        while IFS= read -r child; do
            children+=("$child")
        done < <(find "$author_dir" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
        if (( ${#children[@]} == 0 )); then
            merge_record "$status" "$reason" "$author" "-" "-"
        else
            for child in "${children[@]}"; do
                merge_record "$status" "$reason" "$author" \
                    "${child##*/}" "-"
            done
        fi
        return
    fi

    local child
    while IFS= read -r child; do
        name="${child##*/}"

        if [[ -d "$child" ]]; then
            merge_record "skipped" "nested folder (out of scope)" \
                "$author" "$name" "-"
            continue
        fi

        if [[ ! -f "$child" ]]; then
            merge_record "skipped" "not a regular file" \
                "$author" "$name" "-"
            continue
        fi

        target="$dest_dir/$name"

        if [[ -e "$target" ]]; then
            # Written earlier THIS run by a different source file: collision
            # (same destination name, possibly different content).  Same
            # source file twice is a true duplicate; anything pre-existing
            # is a duplicate-name skip (never overwrite).
            if [[ -n "${DEST_SOURCE[$target]:-}" ]]; then
                if [[ "${DEST_SOURCE[$target]}" == "$child" ]]; then
                    merge_record "duplicate" "same source file copied twice" \
                        "$author" "$name" "$MATCH_DEST/$name"
                else
                    merge_record "collision" \
                        "destination name already written this run by ${DEST_SOURCE[$target]##*/}" \
                        "$author" "$name" "$MATCH_DEST/$name"
                fi
            else
                merge_record "duplicate-name" \
                    "a file with this name already exists at the destination" \
                    "$author" "$name" "$MATCH_DEST/$name"
            fi
            continue
        fi

        if [[ "$DRY_RUN" == true ]]; then
            # Register the would-be target so a later author colliding with
            # it is reported as a collision, not as a pre-existing file.
            DEST_SOURCE[$target]="$child"
            merge_record "would-copy" "dry run: no files were copied" \
                "$author" "$name" "$MATCH_DEST/$name"
        else
            if cp -p -- "$child" "$target"; then
                DEST_SOURCE[$target]="$child"
                merge_record "copied" "" "$author" "$name" "$MATCH_DEST/$name"
            else
                merge_record "skipped" "copy failed" \
                    "$author" "$name" "$MATCH_DEST/$name"
            fi
        fi
    done < <(find "$author_dir" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
}

# -----------------------------------------------------------------------------
# merge_prepare_reports
# -----------------------------------------------------------------------------
# Create REPORT_DIR and write the TSV header to every report file so even an
# empty run produces parseable output.
# -----------------------------------------------------------------------------
merge_prepare_reports() {
    mkdir -p "$REPORT_DIR"
    PROCESSED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

    MANIFEST="$REPORT_DIR/merge-manifest.tsv"
    UNMATCHED_AUTHORS="$REPORT_DIR/unmatched-authors.tsv"
    AMBIGUOUS_AUTHORS="$REPORT_DIR/ambiguous-authors.tsv"
    COLLISIONS="$REPORT_DIR/collisions.tsv"
    DUPLICATES="$REPORT_DIR/duplicates.tsv"
    SKIPPED_FILES="$REPORT_DIR/skipped-files.tsv"

    local header
    header="processed_at	source_author	source_file	destination_file	status	reason"
    for f in "$MANIFEST" "$UNMATCHED_AUTHORS" "$AMBIGUOUS_AUTHORS" \
             "$COLLISIONS" "$DUPLICATES" "$SKIPPED_FILES"; do
        printf '%s\n' "$header" > "$f"
    done
}

# -----------------------------------------------------------------------------
# merge_main
# -----------------------------------------------------------------------------
# Program entry point: parse, validate, collect the skeleton, process every
# author folder, and print a summary.
# -----------------------------------------------------------------------------
merge_main() {
    merge_parse_args "$@"

    if [[ -z "$SOURCE_DIR" ]]; then
        echo "Error: no source directory given (--source)." >&2
        merge_usage
        exit 1
    fi
    if [[ -z "$SKELETON_ROOT" ]]; then
        echo "Error: no skeleton directory given (--skeleton)." >&2
        merge_usage
        exit 1
    fi
    if [[ ! -d "$SOURCE_DIR" ]]; then
        echo "Error: source directory '$SOURCE_DIR' does not exist or is not a directory." >&2
        exit 1
    fi
    if [[ ! -d "$SKELETON_ROOT" ]]; then
        echo "Error: skeleton directory '$SKELETON_ROOT' does not exist or is not a directory." >&2
        echo "Build it first with bin/build_shell_nested_authors.sh." >&2
        exit 1
    fi

    merge_prepare_reports
    merge_collect_skeleton_dirs

    local version
    version="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"
    echo "merge_books_into_skeleton.sh v$version"
    echo "  source:   $SOURCE_DIR"
    echo "  skeleton: $SKELETON_ROOT"
    echo "  reports:  $REPORT_DIR"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  mode:     DRY RUN - nothing will be copied"
    fi

    local author_dir authors=0
    while IFS= read -r author_dir; do
        merge_process_author "$author_dir"
        authors=$((authors + 1))
    done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

    # Summary counts, derived from the manifest rows (excluding the header).
    local total copied dup dupname coll unmatched amb skipped
    total="$(awk 'NR>1 {n++} END{print n+0}' "$MANIFEST")"
    copied="$(awk -F '\t' 'NR>1 && $5=="copied" {n++} END{print n+0}' "$MANIFEST")"
    dup="$(awk -F '\t' 'NR>1 && $5=="duplicate" {n++} END{print n+0}' "$MANIFEST")"
    dupname="$(awk -F '\t' 'NR>1 && $5=="duplicate-name" {n++} END{print n+0}' "$MANIFEST")"
    coll="$(awk -F '\t' 'NR>1 && $5=="collision" {n++} END{print n+0}' "$MANIFEST")"
    unmatched="$(awk -F '\t' 'NR>1 && $5=="unmatched-author" {n++} END{print n+0}' "$MANIFEST")"
    amb="$(awk -F '\t' 'NR>1 && $5=="ambiguous-author" {n++} END{print n+0}' "$MANIFEST")"
    skipped="$(awk -F '\t' 'NR>1 && $5=="skipped" {n++} END{print n+0}' "$MANIFEST")"

    echo ""
    echo "authors: $authors   records: $total"
    echo "  copied: $copied   duplicate: $dup   duplicate-name: $dupname"
    echo "  collision: $coll   unmatched: $unmatched   ambiguous: $amb   skipped: $skipped"
    echo "reports written to $REPORT_DIR"
}
