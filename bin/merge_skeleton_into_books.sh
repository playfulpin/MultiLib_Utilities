#!/usr/bin/env bash

###############################################################################
# bin/merge_skeleton_into_books.sh
#
# Version:       0.2.0
# Last updated:  2026-09-01
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Finalize a timestamped staging tree (BooksInput_<ts>, produced by
#   bin/merge_books_into_skeleton.sh, already pruned) into the Books library
#   with rsync.  The destination wins: --ignore-existing never overwrites a
#   file already present in the library.  A per-file TSV report records every
#   copied file and every kept-existing conflict.
#
#   The old three-step finalize (rename -> prune -> copy loop) is gone: the
#   merge tool now emits the staging tree under its final BooksInput_<ts>
#   name, already pruned, so only the copy remains -- and rsync does it
#   resumably and safely.
#
# -----------------------------------------------------------------------------
# CONFIGURATION PRIORITY
# -----------------------------------------------------------------------------
#   flag > environment variable > config file > built-in default
#
#   Environment variables:
#     MERGE_SOURCE_DIR     explicit staging tree (optional; when unset the
#                          newest BooksInput_* folder under OUTPUT_DIR is used)
#     MERGE_OUTPUT_DIR     discovery root for BooksInput_* (unused when
#                          MERGE_SOURCE_DIR is set)
#     MERGE_TARGET_DIR     the Books library
#     MERGE_REPORT_DIR     where the TSV report is written
#
#   Config file (optional):
#     config/merge_skeleton_into_books.conf
#     or any file given with --config=FILE
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/merge_skeleton_into_books.sh \
#       --target /mnt/c/Backup_Go7/Books \
#       --report-dir /mnt/c/Backup_Go7/merge-reports \
#       --dry-run
#
#   With no --source, the newest BooksInput_* folder under the output root
#   is used.  Always --dry-run first (rows are would-copy / would-keep).
#
# -----------------------------------------------------------------------------
# REPORT
# -----------------------------------------------------------------------------
#   merge_skeleton_into_books_<ts>.tsv in REPORT_DIR, one row per file in
#   the staging tree:
#       source_file<TAB>target_file<TAB>status<TAB>reason
#   status: copied | would-copy | kept-existing | would-keep
#
# REQUIRES: rsync on PATH.
#
###############################################################################

set -euo pipefail

# --- built-in defaults -------------------------------------------------------
SOURCE_DIR=""                      # empty => auto-discover newest BooksInput_*
OUTPUT_ROOT="/mnt/c/Backup_Go7"
TARGET_DIR="/mnt/c/Backup_Go7/Books"
REPORT_DIR="/mnt/c/Backup_Go7/merge-reports"
DRY_RUN=false
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
            OUTPUT_DIR) OUTPUT_ROOT="$value" ;;
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
    if [[ -n "${MERGE_OUTPUT_DIR:-}" ]]; then
        OUTPUT_ROOT="$MERGE_OUTPUT_DIR"
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
    echo "Usage: $0 [OPTIONS] --target=DIR" >&2
    echo "" >&2
    echo "Optional:" >&2
    echo "  -s, --source=DIR     Staging tree (BooksInput_*); when omitted," >&2
    echo "                       the newest BooksInput_* under --output-root" >&2
    echo "                       is used" >&2
    echo "  -t, --target=DIR     Books library to merge into" >&2
    echo "  -o, --output-root=DIR  Discovery root for BooksInput_* [default: /mnt/c/Backup_Go7]" >&2
    echo "      --report-dir=DIR   Report directory [default: /mnt/c/Backup_Go7/merge-reports]" >&2
    echo "      --config=FILE      Load defaults from this config file" >&2
    echo "      --dry-run          Show what rsync would copy, write report," >&2
    echo "                         change nothing" >&2
    echo "  -v, --version          Print version and exit 0" >&2
    echo "  -h, --help             Show this help" >&2
    echo "" >&2
    echo "Sync: rsync -a --ignore-existing (the destination wins, nothing is" >&2
    echo "overwritten).  Requires rsync on PATH." >&2
    echo "" >&2
    echo "Priority: flag > environment > config file > built-in default" >&2
    echo "Environment: MERGE_SOURCE_DIR, MERGE_OUTPUT_DIR, MERGE_TARGET_DIR, MERGE_REPORT_DIR" >&2
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
            --output-root=*|--report-dir=*|--config=*|-s=*|--source=*|-t=*|--target=*|-o=*)
                case "$1" in
                    --output-root=*|-o=*) OUTPUT_ROOT="${1#*=}" ;;
                    --report-dir=*)       REPORT_DIR="${1#*=}" ;;
                    --config=*)           CONFIG_FILE="${1#*=}" ;;
                    -s=*|--source=*)      SOURCE_DIR="${1#*=}" ;;
                    -t=*|--target=*)      TARGET_DIR="${1#*=}" ;;
                esac
                ;;
            --output-root|-o|--report-dir|--config|-s|--source|-t|--target)
                local flag="$1"
                shift
                [[ $# -gt 0 ]] || { echo "Error: $flag requires a value." >&2; exit 1; }
                case "$flag" in
                    --output-root|-o) OUTPUT_ROOT="$1" ;;
                    --report-dir)     REPORT_DIR="$1" ;;
                    --config)         CONFIG_FILE="$1" ;;
                    -s|--source)      SOURCE_DIR="$1" ;;
                    -t|--target)      TARGET_DIR="$1" ;;
                esac
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
    # rsync must exist
    # ------------------------------------------------------------------
    if ! command -v rsync >/dev/null 2>&1; then
        echo "Error: rsync not found on PATH; install it (WSL: sudo apt install rsync)." >&2
        exit 1
    fi

    # ------------------------------------------------------------------
    # 4. Resolve the staging source (explicit or auto-discovered)
    # ------------------------------------------------------------------
    if [[ -z "$SOURCE_DIR" ]]; then
        case "$OUTPUT_ROOT" in
            ""|"/"|"//"|"$HOME"|"$HOME"/*)
                echo "Error: refusing to search dangerous output root '$OUTPUT_ROOT'." >&2
                exit 1
                ;;
        esac
        [[ -d "$OUTPUT_ROOT" ]] || { echo "Error: output root '$OUTPUT_ROOT' is not a directory." >&2; exit 1; }

        SOURCE_DIR="$(find "$OUTPUT_ROOT" -maxdepth 1 -type d -name 'BooksInput_*' -print 2>/dev/null | LC_ALL=C sort -r | head -n 1)"
        if [[ -z "$SOURCE_DIR" ]]; then
            echo "Error: no BooksInput_* staging folder found under '$OUTPUT_ROOT'." >&2
            exit 1
        fi
        echo "auto-discovered staging: $SOURCE_DIR"
    fi

    # ------------------------------------------------------------------
    # 5. Validation
    # ------------------------------------------------------------------
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
    case "$SOURCE_DIR" in
        "$TARGET_DIR"|"$TARGET_DIR"/*)
            echo "Error: source '$SOURCE_DIR' is inside target '$TARGET_DIR'." >&2
            exit 1
            ;;
    esac

    local source_base
    source_base="$(basename "$SOURCE_DIR")"
    if [[ "$source_base" != BooksInput_* ]]; then
        echo "Error: source name does not start with BooksInput_ ('$source_base')." >&2
        exit 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "## DRY RUN - nothing will be changed ##"
    fi

    # ------------------------------------------------------------------
    # 6. Report header
    # ------------------------------------------------------------------
    local report_stamp report_dir
    report_stamp="$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$REPORT_DIR"
    REPORT_FILE="$REPORT_DIR/merge_skeleton_into_books_$report_stamp.tsv"
    if ! printf 'source_file\ttarget_file\tstatus\treason\n' > "$REPORT_FILE"; then
        echo "Warning: cannot write report '$REPORT_FILE'; continuing without one." >&2
        REPORT_FILE=""
    fi

    # ------------------------------------------------------------------
    # 7. rsync: destination wins, never overwrite, resumable
    # ------------------------------------------------------------------
    # -a                 archive mode (recursive, times, perms)
    # --ignore-existing  a file already in the library is never replaced
    # --itemize-changes  per-file change lines on stdout
    # --exclude          Windows metadata, belt-and-braces (merge already
    #                    filters them, but never let one into the library)
    # trailing slash     copy the CONTENTS of the staging tree, not the
    #                    folder itself
    local tmp transferred tint
    tmp="$(mktemp)"
    printf '' > "$tmp"

    local -a args=( -a --ignore-existing --itemize-changes \
                    --exclude=desktop.ini --exclude=Thumbs.db )
    if [[ "$DRY_RUN" == true ]]; then
        args+=( -n )
    fi

    echo "sync: rsync ${args[*]} '$SOURCE_DIR/' '$TARGET_DIR/'"
    set +e
    rsync "${args[@]}" "$SOURCE_DIR/" "$TARGET_DIR/" > "$tmp" 2>&1
    local rsync_rc=$?
    set -e

    # Transferred file rows start with '>' (e.g. ">f+++++++++ rel"); dirs
    # ("cd+++++++++ rel/") and skipped files are not rows.
    transferred="$(grep -E '^>' "$tmp" | sed -n 's/^.\{11\} \(.*\)$/\1/p' | grep -v '/$' | grep -v '^$' || true)"

    # ------------------------------------------------------------------
    # 8. Report rows: one per staging file
    # ------------------------------------------------------------------
    local copied=0 kept=0 f rel target tfile
    while IFS= read -r -d '' f; do
        rel="${f#"$SOURCE_DIR"/}"
        target="$TARGET_DIR/$rel"

        if grep -Fxq "$rel" <(printf '%s\n' "$transferred"); then
            if [[ "$DRY_RUN" == true ]]; then
                report_row "$rel" "$target" "would-copy" ""
                copied=$((copied + 1))
            else
                report_row "$rel" "$target" "copied" ""
                copied=$((copied + 1))
            fi
        elif [[ -e "$target" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                report_row "$rel" "$target" "would-keep" "already present in the library"
                kept=$((kept + 1))
            else
                report_row "$rel" "$target" "kept-existing" "already present in the library"
                kept=$((kept + 1))
            fi
        else
            if [[ "$DRY_RUN" == true ]]; then
                report_row "$rel" "$target" "would-copy" "rsync did not list it"
                copied=$((copied + 1))
            else
                report_row "$rel" "$target" "failed" "rsync did not copy it"
                echo "Warning: '$rel' was not copied by rsync." >&2
            fi
        fi
    done < <(find "$SOURCE_DIR" -type f -print0)

    rm -f "$tmp"

    echo ""
    echo "copied: $copied   kept-existing: $kept"
    if [[ "$DRY_RUN" == true ]]; then
        echo "nothing was changed (dry run)."
    elif (( rsync_rc == 0 )); then
        echo "staging folder retained at: $SOURCE_DIR"
    fi
    if [[ -n "$REPORT_FILE" ]]; then
        echo "report: $REPORT_FILE"
    fi

    if (( rsync_rc != 0 )); then
        echo "Error: rsync exited with status $rsync_rc." >&2
        exit 1
    fi
}

main "$@"