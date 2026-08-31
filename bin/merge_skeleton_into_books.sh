#!/usr/bin/env bash

###############################################################################
# bin/merge_skeleton_into_books.sh
#
# Version:       0.1.0
# Last updated:  2026-08-30 21:46
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Finalize a populated author-prefix skeleton (Empty_Skeleton) into the
#   Books library in three safe steps:
#
#     1. rename the skeleton to a timestamped staging folder BooksInput_<ts>;
#     2. remove every empty directory inside the staging folder;
#     3. copy the remaining content into the Books library, never
#        overwriting an existing folder or file (the destination wins).
#
#   The staging folder is the INPUT.  Nothing in it is deleted except empty
#   directories, and after the copy it is left intact so you can inspect or
#   reuse it.  This is the finalize step that comes after building the
#   skeleton and merging the archive books into it.
#
# -----------------------------------------------------------------------------
# EXAMPLES
# -----------------------------------------------------------------------------
#   ./bin/merge_skeleton_into_books.sh \
#       --source /mnt/c/Backup_Nova3/Empty_Skeleton \
#       --target /mnt/c/Backup_Nova3/Books \
#       --dry-run
#
#   Always run --dry-run first and review the report, then drop --dry-run
#   to actually rename, prune, and copy.
#
# -----------------------------------------------------------------------------
# REPORT
# -----------------------------------------------------------------------------
#   A TSV report is written to the current directory,
#   merge_skeleton_into_books_<timestamp>.tsv: one row per file with status
#   `copied` or `kept-existing` (in a dry run `would-copy` / `would-keep`).
#   Nothing in the library or the staging folder is modified by a dry run.
#
###############################################################################

set -euo pipefail

# --- configuration (flag > default) ------------------------------------------
SOURCE_DIR="/mnt/c/Backup_Nova3/Empty_Skeleton"
TARGET_DIR="/mnt/c/Backup_Nova3/Books"
DRY_RUN=false
PRUNE_EMPTY=true
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
REPORT_DIR="$PWD"

# --- globals used only by main() ---------------------------------------------
REPORT_FILE=""

# -----------------------------------------------------------------------------
# usage
# -----------------------------------------------------------------------------
# Print the command-line contract to standard error and exit 1 (repo
# convention: usage() always exits non-zero, including for -h).
# -----------------------------------------------------------------------------
usage() {
    local version
    version="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"
    echo "bin/merge_skeleton_into_books.sh v$version" >&2
    echo "" >&2
    echo "Usage: $0 --source=DIR --target=DIR [OPTIONS]" >&2
    echo "" >&2
    echo "Required:" >&2
    echo "  -s, --source=DIR  Source skeleton to rename (then prune + copy)" >&2
    echo "  -t, --target=DIR  Books library to merge into (destination wins)" >&2
    echo "" >&2
    echo "Optional:" >&2
    echo "      --timestamp=STAMP  Suffix for the BooksInput_<stamp> name" >&2
    echo "                         [default: YYYYMMDD-HHMMSS]" >&2
    echo "      --report-dir=DIR   Where the TSV report file is written" >&2
    echo "                         [default: \$PWD]" >&2
    echo "      --no-rename        Skip the rename to BooksInput_<stamp>" >&2
    echo "      --no-prune         Leave empty directories in place" >&2
    echo "      --dry-run          Show the steps and report, change nothing" >&2
    echo "  -v, --version          Print the version and exit 0" >&2
    echo "  -h, --help             Show this help message" >&2
}

# -----------------------------------------------------------------------------
# parse_arguments
# -----------------------------------------------------------------------------
# Accept -s, -s DIR, --source=DIR and -t variants in combined or isolated
# form; "--" ends option parsing.  Unknown options fail loudly.
# -----------------------------------------------------------------------------
parse_arguments() {
    local arg flag value
    local source_pos="" target_pos=""

    while (( $# > 0 )); do
        arg="$1"

        case "$arg" in
            -h|--help)
                usage
                exit 1
                ;;
            -v|--version)
                echo "merge_skeleton_into_books.sh v$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --no-rename)
                RENAME=false
                ;;
            --no-prune)
                PRUNE_EMPTY=false
                ;;
            --timestamp=*)
                TIMESTAMP="${arg#*=}"
                ;;
            --timestamp)
                if (( $# < 2 )); then
                    echo "Error: --timestamp requires a value." >&2
                    exit 1
                fi
                TIMESTAMP="$2"
                shift
                ;;
            --report-dir=*)
                REPORT_DIR="${arg#*=}"
                ;;
            --report-dir)
                if (( $# < 2 )); then
                    echo "Error: --report-dir requires a value." >&2
                    exit 1
                fi
                REPORT_DIR="$2"
                shift
                ;;
            -s=*|--source=*|-t=*|--target=*)
                flag="${arg%%=*}"
                value="${arg#*=}"
                if [[ -z "$value" ]]; then
                    echo "Error: $flag requires a value." >&2
                    exit 1
                fi
                case "$flag" in
                    -s|--source) SOURCE_DIR="$value" ;;
                    -t|--target) TARGET_DIR="$value" ;;
                esac
                ;;
            -s|--source|-t|--target)
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
                    -s|--source) SOURCE_DIR="$value" ;;
                    -t|--target) TARGET_DIR="$value" ;;
                esac
                shift
                ;;
            --)
                shift
                while (( $# > 0 )); do
                    if [[ -z "$source_pos" ]]; then
                        SOURCE_DIR="$1"; source_pos=1
                    elif [[ -z "$target_pos" ]]; then
                        TARGET_DIR="$1"; target_pos=1
                    else
                        echo "Error: Too many positional arguments." >&2
                        usage
                        exit 1
                    fi
                    shift
                done
                break
                ;;
            -*)
                echo "Error: Unexpected option or argument '$arg'." >&2
                usage
                exit 1
                ;;
            *)
                if [[ -z "$source_pos" ]]; then
                    SOURCE_DIR="$arg"; source_pos=1
                elif [[ -z "$target_pos" ]]; then
                    TARGET_DIR="$arg"; target_pos=1
                else
                    echo "Error: Too many positional arguments." >&2
                    usage
                    exit 1
                fi
                ;;
        esac

        shift
    done
}

# -----------------------------------------------------------------------------
# report_row
# -----------------------------------------------------------------------------
# Append one TSV row to the report (a no-op when no report could be opened).
# -----------------------------------------------------------------------------
report_row() {
    [[ -n "$REPORT_FILE" ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$REPORT_FILE"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    parse_arguments "$@"

    [[ -n "$SOURCE_DIR" ]] || { echo "Error: no source given (--source)." >&2; usage; exit 1; }
    [[ -n "$TARGET_DIR" ]] || { echo "Error: no target given (--target)." >&2; usage; exit 1; }
    [[ -d "$SOURCE_DIR" ]] || { echo "Error: source '$SOURCE_DIR' is not a directory." >&2; exit 1; }
    [[ -d "$TARGET_DIR" ]] || { echo "Error: target '$TARGET_DIR' is not a directory." >&2; exit 1; }

    case "$SOURCE_DIR" in
        ""|"/"|"//"|"$HOME"|"$HOME"/*)
            echo "Error: refusing to rename dangerous source path '$SOURCE_DIR'." >&2
            exit 1
            ;;
    esac
    case "$TARGET_DIR" in
        "$SOURCE_DIR"|"$SOURCE_DIR"/*)
            echo "Error: target '$TARGET_DIR' is inside source '$SOURCE_DIR'." >&2
            exit 1
            ;;
    esac

    if [[ "$DRY_RUN" == true ]]; then
        echo "## DRY RUN - nothing will be changed ##"
    fi

    # --- step 1: rename -------------------------------------------------------
    local source_parent staging tree_source
    source_parent="$(cd "$(dirname "$SOURCE_DIR")" && pwd)"
    staging="$source_parent/BooksInput_$TIMESTAMP"

    if [[ "$RENAME" == false ]]; then
        echo "step 1: skipped (--no-rename)"
        tree_source="$SOURCE_DIR"
    else
        if [[ -e "$staging" ]]; then
            echo "Error: '$staging' already exists; pass a different --timestamp." >&2
            exit 1
        fi
        echo "step 1: rename '$SOURCE_DIR' -> '$staging'"
        if [[ "$DRY_RUN" == false ]]; then
            mv -- "$SOURCE_DIR" "$staging"
            echo "       renamed."
            tree_source="$staging"
        else
            echo "       (dry run) would rename."
            tree_source="$SOURCE_DIR"
        fi
    fi

    # --- step 2: prune empty directories -------------------------------------
    if [[ "$PRUNE_EMPTY" == false ]]; then
        echo "step 2: skip empty-directory pruning (--no-prune)."
    else
        local empty_count label
        empty_count="$(find "$tree_source" -type d -empty | wc -l)"
        if (( empty_count == 1 )); then
            label="directory"
        else
            label="directories"
        fi
        echo "step 2: remove $empty_count empty $label."
        if (( empty_count > 0 )); then
            if [[ "$DRY_RUN" == false ]]; then
                find "$tree_source" -depth -type d -empty -delete
                echo "       pruned."
            else
                echo "       (dry run) would prune."
            fi
        else
            echo "       nothing to prune."
        fi
    fi

    # --- step 3: merge (copy, never overwrite) --------------------------------
    mkdir -p "$REPORT_DIR"
    REPORT_FILE="$REPORT_DIR/merge_skeleton_into_books_$TIMESTAMP.tsv"
    if ! { printf 'source_file\ttarget_file\tstatus\treason\n' > "$REPORT_FILE"; }; then
        echo "Warning: cannot write report '$REPORT_FILE'; continuing without one." >&2
        REPORT_FILE=""
    fi

    echo "step 3: copy unique content from '$tree_source' into '$TARGET_DIR'"
    local copied=0 kept=0 rel target
    while IFS= read -r -d '' f; do
        rel="${f#"$tree_source"/}"
        target="$TARGET_DIR/$rel"
        if [[ -e "$target" ]]; then
            report_row "$rel" "$target" "kept-existing" "already present in the library"
            kept=$((kept + 1))
        else
            if [[ "$DRY_RUN" == true ]]; then
                report_row "$rel" "$target" "would-copy" ""
                copied=$((copied + 1))
            else
                mkdir -p -- "$(dirname "$target")"
                if cp -p -- "$f" "$target"; then
                    report_row "$rel" "$target" "copied" ""
                    copied=$((copied + 1))
                else
                    report_row "$rel" "$target" "failed" "copy error"
                    echo "Error: could not copy '$rel'." >&2
                fi
            fi
        fi
    done < <(find "$tree_source" -type f -print0)

    echo ""
    echo "copied: $copied   kept-existing: $kept"
    if [[ "$DRY_RUN" == true ]]; then
        echo "nothing was changed (dry run)."
    else
        echo "staging folder retained at: $staging"
    fi
    [[ -n "$REPORT_FILE" ]] && echo "report: $REPORT_FILE"
}

# Defaults that parse_arguments and main read; declared after use is fine in
# bash (they are set before main runs).
RENAME=true

main "$@"