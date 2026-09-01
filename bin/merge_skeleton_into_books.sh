#!/usr/bin/env bash

###############################################################################
# bin/merge_skeleton_into_books.sh
#
# Version:       0.1.2
# Last updated:  2026-08-31 19:50
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Finalize a populated author-prefix skeleton into the Books library in
#   three safe steps:
#
#     1. rename the skeleton to a timestamped staging folder BooksInput_<ts>;
#     2. remove every empty directory inside the staging folder;
#     3. copy the remaining content into the Books library, never
#        overwriting an existing folder or file (the destination wins).
#
#   Starting after the prune step is supported in two ways:
#     • --from-pruned          (explicit)
#     • source name BooksInput_* (auto-detected)
#
# -----------------------------------------------------------------------------
# CONFIGURATION PRIORITY
# -----------------------------------------------------------------------------
#   flag > environment variable > config file > built-in default
#
#   Environment variables:
#     MERGE_SOURCE_DIR, MERGE_TARGET_DIR, MERGE_REPORT_DIR
#
#   Config file (optional):
#     config/merge_skeleton_into_books.conf
#     or any file given with --config=FILE
#
###############################################################################

set -euo pipefail

# --- built-in defaults -------------------------------------------------------
SOURCE_DIR="/mnt/c/Backup_Nova3/Empty_Skeleton"
TARGET_DIR="/mnt/c/Backup_Nova3/Books"
REPORT_DIR="/mnt/c/Backup_Nova3/merge-reports"
DRY_RUN=false
RENAME=true
PRUNE_EMPTY=true
FROM_PRUNED=false
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
CONFIG_FILE=""
REPORT_FILE=""

# -----------------------------------------------------------------------------
# load_config
# -----------------------------------------------------------------------------
load_config() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local line key value
    # Use process substitution + || true so a missing final newline never
    # triggers set -e.
    while IFS= read -r line || [[ -n "$line" ]]; do
        # skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue

        key="${line%%=*}"
        value="${line#*=}"

        # trim whitespace
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        case "$key" in
            SOURCE_DIR) SOURCE_DIR="$value" ;;
            TARGET_DIR) TARGET_DIR="$value" ;;
            REPORT_DIR) REPORT_DIR="$value" ;;
            *)
                echo "Warning: unknown config key '$key' in $file (ignored)" >&2
                ;;
        esac
    done < "$file" || true
}

# -----------------------------------------------------------------------------
# apply_environment
# -----------------------------------------------------------------------------
apply_environment() {
    if [[ -n "${MERGE_SOURCE_DIR:-}" ]]; then
        SOURCE_DIR="$MERGE_SOURCE_DIR"
    fi
    if [[ -n "${MERGE_TARGET_DIR:-}" ]]; then
        TARGET_DIR="$MERGE_TARGET_DIR"
    fi
    if [[ -n "${MERGE_REPORT_DIR:-}" ]]; then
        REPORT_DIR="$MERGE_REPORT_DIR"
    fi
}

# -----------------------------------------------------------------------------
# usage
# -----------------------------------------------------------------------------
usage() {
    local version
    version="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"
    echo "bin/merge_skeleton_into_books.sh v$version" >&2
    echo "" >&2
    echo "Usage: $0 [OPTIONS] --source=DIR --target=DIR" >&2
    echo "" >&2
    echo "Required:" >&2
    echo "  -s, --source=DIR     Source skeleton (or BooksInput_* folder)" >&2
    echo "  -t, --target=DIR     Books library to merge into" >&2
    echo "" >&2
    echo "Optional:" >&2
    echo "      --timestamp=STAMP  Suffix for BooksInput_<stamp> [default: YYYYMMDD-HHMMSS]" >&2
    echo "      --report-dir=DIR   Report directory [default: /mnt/c/Backup_Nova3/merge-reports]" >&2
    echo "      --config=FILE      Load defaults from this config file" >&2
    echo "      --from-pruned      Skip rename + prune (source is already pruned)" >&2
    echo "      --no-rename        Skip the rename step only" >&2
    echo "      --no-prune         Leave empty directories in place" >&2
    echo "      --dry-run          Show steps and write report, change nothing" >&2
    echo "  -v, --version          Print version and exit 0" >&2
    echo "  -h, --help             Show this help" >&2
    echo "" >&2
    echo "Priority: flag > environment > config file > built-in default" >&2
    echo "Environment: MERGE_SOURCE_DIR, MERGE_TARGET_DIR, MERGE_REPORT_DIR" >&2
}

# -----------------------------------------------------------------------------
# parse_arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
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
            --from-pruned)
                FROM_PRUNED=true
                ;;
            --no-rename)
                RENAME=false
                ;;
            --no-prune)
                PRUNE_EMPTY=false
                ;;
            --timestamp=*)
                TIMESTAMP="${1#*=}"
                ;;
            --timestamp)
                shift
                [[ $# -gt 0 ]] || { echo "Error: --timestamp requires a value." >&2; exit 1; }
                TIMESTAMP="$1"
                ;;
            --report-dir=*)
                REPORT_DIR="${1#*=}"
                ;;
            --report-dir)
                shift
                [[ $# -gt 0 ]] || { echo "Error: --report-dir requires a value." >&2; exit 1; }
                REPORT_DIR="$1"
                ;;
            --config=*)
                CONFIG_FILE="${1#*=}"
                ;;
            --config)
                shift
                [[ $# -gt 0 ]] || { echo "Error: --config requires a value." >&2; exit 1; }
                CONFIG_FILE="$1"
                ;;
            -s|--source)
                shift
                [[ $# -gt 0 ]] || { echo "Error: --source requires a value." >&2; exit 1; }
                SOURCE_DIR="$1"
                ;;
            -s=*|--source=*)
                SOURCE_DIR="${1#*=}"
                ;;
            -t|--target)
                shift
                [[ $# -gt 0 ]] || { echo "Error: --target requires a value." >&2; exit 1; }
                TARGET_DIR="$1"
                ;;
            -t=*|--target=*)
                TARGET_DIR="${1#*=}"
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Error: unexpected option '$1'." >&2
                usage
                exit 1
                ;;
            *)
                echo "Error: unexpected argument '$1'." >&2
                usage
                exit 1
                ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# report_row
# -----------------------------------------------------------------------------
report_row() {
    [[ -n "$REPORT_FILE" ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$REPORT_FILE"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    # ------------------------------------------------------------------
    # 1. Load config file (lowest priority after built-in defaults)
    # ------------------------------------------------------------------
    local script_dir default_config
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    default_config="$script_dir/../config/merge_skeleton_into_books.conf"

    if [[ -n "$CONFIG_FILE" ]]; then
        load_config "$CONFIG_FILE"
    elif [[ -f "$default_config" ]]; then
        load_config "$default_config"
    fi

    # ------------------------------------------------------------------
    # 2. Environment variables override config
    # ------------------------------------------------------------------
    apply_environment

    # ------------------------------------------------------------------
    # 3. Command-line flags override everything
    # ------------------------------------------------------------------
    parse_arguments "$@"

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------
    [[ -n "$SOURCE_DIR" ]] || { echo "Error: no source given (--source)." >&2; usage; exit 1; }
    [[ -n "$TARGET_DIR" ]] || { echo "Error: no target given (--target)." >&2; usage; exit 1; }
    [[ -d "$SOURCE_DIR" ]] || { echo "Error: source '$SOURCE_DIR' is not a directory." >&2; exit 1; }
    [[ -d "$TARGET_DIR" ]] || { echo "Error: target '$TARGET_DIR' is not a directory." >&2; exit 1; }

    case "$SOURCE_DIR" in
        ""|"/"|"//"|"$HOME"|"$HOME"/*)
            echo "Error: refusing to operate on dangerous source path '$SOURCE_DIR'." >&2
            exit 1
            ;;
    esac
    case "$TARGET_DIR" in
        "$SOURCE_DIR"|"$SOURCE_DIR"/*)
            echo "Error: target '$TARGET_DIR' is inside source '$SOURCE_DIR'." >&2
            exit 1
            ;;
    esac

    # ------------------------------------------------------------------
    # Decide whether we start after the prune step
    # ------------------------------------------------------------------
    local source_base
    source_base="$(basename "$SOURCE_DIR")"

    if [[ "$FROM_PRUNED" == true ]]; then
        RENAME=false
        PRUNE_EMPTY=false
        if [[ "$source_base" != BooksInput_* ]]; then
            echo "Warning: --from-pruned used but source name does not start with BooksInput_ ('$source_base')." >&2
        fi
        echo "mode: from-pruned (skip rename + prune)"
    elif [[ "$source_base" == BooksInput_* ]]; then
        RENAME=false
        PRUNE_EMPTY=false
        echo "mode: auto-detected BooksInput_* source → skip rename + prune"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "## DRY RUN - nothing will be changed ##"
    fi

    # ------------------------------------------------------------------
    # Step 1: rename
    # ------------------------------------------------------------------
    local source_parent staging tree_source
    source_parent="$(cd "$(dirname "$SOURCE_DIR")" && pwd)"
    staging="$source_parent/BooksInput_$TIMESTAMP"

    if [[ "$RENAME" == false ]]; then
        echo "step 1: skipped (rename not required)"
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

    # ------------------------------------------------------------------
    # Step 2: prune empty directories
    # ------------------------------------------------------------------
    if [[ "$PRUNE_EMPTY" == false ]]; then
        echo "step 2: skip empty-directory pruning."
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

    # ------------------------------------------------------------------
    # Step 3: copy (never overwrite)
    # ------------------------------------------------------------------
    mkdir -p "$REPORT_DIR"
    REPORT_FILE="$REPORT_DIR/merge_skeleton_into_books_$TIMESTAMP.tsv"
    if ! printf 'source_file\ttarget_file\tstatus\treason\n' > "$REPORT_FILE"; then
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
        if [[ "$RENAME" == true ]]; then
            echo "staging folder retained at: $staging"
        else
            echo "source folder retained at: $tree_source"
        fi
    fi
    if [[ -n "$REPORT_FILE" ]]; then
        echo "report: $REPORT_FILE"
    fi
}

main "$@"