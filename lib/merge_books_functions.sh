#!/usr/bin/env bash

###############################################################################
# lib/merge_books_functions.sh
#
# Version:       0.1.2
# Last updated:  2026-08-30 21:00
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Shared functions for bin/merge_books_into_skeleton.sh: copy every file
#   of every top-level author folder in a source archive into the deepest
#   valid prefix directory of a pre-built author skeleton, without losing
#   the book-series structure and without overwriting anything the user has
#   not explicitly allowed.
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
#   The author itself becomes a DIRECTORY under that prefix, so books never
#   collide between authors that share a prefix:
#
#       source:  Абби Линн/Magic The Gathering/0Мироходец.zip
#       dest:    А/Аб/Абби Линн/Magic The Gathering/0Мироходец.zip
#
#   Windows metadata files (desktop.ini, Thumbs.db by default) are never
#   copied; the list is configurable via MERGE_SKIP_NAMES.
#
# -----------------------------------------------------------------------------
# CONFIGURATION (resolution order: flag > env var > config file > default)
# -----------------------------------------------------------------------------
#   Values can come from command-line flags, environment variables, the
#   optional config file (config/merge_books.conf, see below), or built-in
#   defaults:
#
#       SOURCE_DIR      top-level author folders (one level only)
#       SKELETON_ROOT   pre-built prefix skeleton (never modified)
#       REPORT_DIR      where the TSV reports are written
#       RECURSIVE       true  => copy book-series subfolders recursively
#                       false => direct files only (folders are skipped)
#       OVERWRITE_POLICY  never|ask|force -- what to do when the
#                       destination file already exists
#       SKIP_NAMES      space-separated basenames that are never copied
#                       (Windows metadata; default: desktop.ini Thumbs.db)
#
#   Config file keys (sourced as shell assignments):
#       MERGE_SOURCE_DIR  MERGE_SKELETON_ROOT  MERGE_REPORT_DIR
#       MERGE_RECURSIVE (ON|OFF)  MERGE_OVERWRITE (never|ask|force)
#       MERGE_SKIP_NAMES (space-separated basenames)
#   The same names work as environment variables.  --dry-run is deliberately
#   NOT configurable: it stays a command-line safety gate.
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
#   3. COPY each file (recursively when RECURSIVE is on, so book-series
#      subfolders keep their relative layout) into
#      <skeleton>/<rel>/<relative-path> unless the destination already
#      exists.  Empty subfolders are never created.  Existing destinations
#      are handled per OVERWRITE_POLICY (never/ask/force); a file written
#      twice by the same source is always skipped as a duplicate.  Every
#      outcome is recorded once in the manifest and once in the specialised
#      report file.
#
#   Prefix matching is deliberately case-sensitive, matching the skeleton
#   builder's LC_ALL=C byte-order semantics: "Толстой" and "толстой" live
#   in different branches of the skeleton.
#
###############################################################################

set -euo pipefail

# --- module state (flags, then env, then config, then defaults) -------------
SOURCE_DIR=""
SKELETON_ROOT=""
REPORT_DIR=""
RECURSIVE=true
OVERWRITE_POLICY="never"
# Space-separated basenames that are never copied (Windows metadata).
SKIP_NAMES="desktop.ini Thumbs.db"
DRY_RUN=false
CONFIG_FILE=""

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
declare -a SKIP_NAME_ARRAY=()  # basenames that are never copied (lowercased)
MATCH_DEST=""                  # resolved destination (relative to skeleton)
MATCH_AMBIGUOUS=false

# --- default config location (next to the repo's config/ directory) ----------
DEFAULT_CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/merge_books.conf"

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
    echo "      --config=FILE     Config file [default: config/merge_books.conf]" >&2
    echo "      --recursive       Copy book-series subfolders recursively [default]" >&2
    echo "      --no-recursive    Direct files only; subfolders are skipped" >&2
    echo "      --overwrite=POL   Destination exists: never|ask|force [default: never]" >&2
    echo "      --dry-run         Resolve and report only; copy nothing" >&2
    echo "  -v, --version         Print the version and exit 0" >&2
    echo "  -h, --help            Show this help message" >&2
    echo "" >&2
    echo "Resolution order for every setting:" >&2
    echo "  command-line flag > environment variable > config file > built-in default" >&2
}

# -----------------------------------------------------------------------------
# merge_parse_args
# -----------------------------------------------------------------------------
# Accept named options in combined (-s=DIR), isolated (-s DIR), or spaced
# (-s = DIR) forms; "--" ends option parsing.  Unknown options fail loudly.
# Values already resolved from the config file / environment are only
# replaced when the matching flag is actually present.
# -----------------------------------------------------------------------------
merge_parse_args() {
    local arg flag value

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
            --config=*)
                CONFIG_FILE="${arg#*=}"   # already loaded by merge_load_config
                ;;
            --config)
                if (( $# < 2 )); then
                    echo "Error: --config requires a value." >&2
                    exit 1
                fi
                CONFIG_FILE="$2"
                shift
                ;;
            --recursive)
                RECURSIVE=true
                ;;
            --no-recursive)
                RECURSIVE=false
                ;;
            --overwrite=*)
                OVERWRITE_POLICY="${arg#*=}"
                ;;
            --overwrite)
                if (( $# < 2 )); then
                    echo "Error: --overwrite requires a value." >&2
                    exit 1
                fi
                OVERWRITE_POLICY="$2"
                shift
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
                # Everything after "--" is positional; nothing else is
                # consumed here (positional slots are filled below).
                while (( $# > 0 )); do
                    if [[ -z "$SOURCE_DIR" ]]; then
                        SOURCE_DIR="$1"
                    elif [[ -z "$SKELETON_ROOT" ]]; then
                        SKELETON_ROOT="$1"
                    else
                        echo "Error: Too many positional arguments." >&2
                        merge_usage
                        exit 1
                    fi
                    shift
                done
                break
                ;;
            -*)
                echo "Error: Unexpected option or argument '$arg'." >&2
                merge_usage
                exit 1
                ;;
            *)
                if [[ -z "$SOURCE_DIR" ]]; then
                    SOURCE_DIR="$arg"
                elif [[ -z "$SKELETON_ROOT" ]]; then
                    SKELETON_ROOT="$arg"
                else
                    echo "Error: Too many positional arguments." >&2
                    merge_usage
                    exit 1
                fi
                ;;
        esac

        shift
    done

    [[ -n "$REPORT_DIR" ]] || REPORT_DIR="$PWD/merge-reports"
}

# -----------------------------------------------------------------------------
# merge_find_config
# -----------------------------------------------------------------------------
# Pre-scan the raw argument list for --config so the config file can be
# loaded BEFORE the full parse fills in the values (flags must win).
# -----------------------------------------------------------------------------
merge_find_config() {
    local arg
    while (( $# > 0 )); do
        arg="$1"
        case "$arg" in
            --config=*)
                CONFIG_FILE="${arg#*=}"
                ;;
            --config)
                if (( $# >= 2 )); then
                    CONFIG_FILE="$2"
                    shift
                fi
                ;;
            --) break ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# merge_normalize_bool
# -----------------------------------------------------------------------------
# Convert a config/env ON|OFF|true|false|1|0 value to true|false.  Invalid
# values abort with a message.
# -----------------------------------------------------------------------------
merge_normalize_bool() {
    case "${1^^}" in
        ON|TRUE|1) printf 'true' ;;
        OFF|FALSE|0) printf 'false' ;;
        *)
            echo "Error: MERGE_RECURSIVE must be ON or OFF, got '$1'." >&2
            exit 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# merge_normalize_overwrite
# -----------------------------------------------------------------------------
# Normalize a policy value to lowercase never|ask|force.  Invalid values
# abort with a message.
# -----------------------------------------------------------------------------
merge_normalize_overwrite() {
    case "${1,,}" in
        never|ask|force) printf '%s' "${1,,}" ;;
        *)
            echo "Error: overwrite policy must be never, ask or force, got '$1'." >&2
            exit 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# merge_load_config
# -----------------------------------------------------------------------------
# Source the config file (explicit --config > $MERGE_CONFIG > the default
# location), then let environment variables override it.  An explicitly
# requested config file that does not exist is an error; the default file is
# optional.  The config values are validated on the way in.
# -----------------------------------------------------------------------------
merge_load_config() {
    local cfg="${CONFIG_FILE:-${MERGE_CONFIG:-$DEFAULT_CONFIG_FILE}}"

    # Capture environment-provided values BEFORE sourcing the config file:
    # a config assignment would otherwise clobber the environment variable
    # and silently defeat the env > config precedence.
    local env_source="${MERGE_SOURCE_DIR:-}"
    local env_skeleton="${MERGE_SKELETON_ROOT:-}"
    local env_report="${MERGE_REPORT_DIR:-}"
    local env_recursive="${MERGE_RECURSIVE:-}"
    local env_overwrite="${MERGE_OVERWRITE:-}"
    local env_skip_names="${MERGE_SKIP_NAMES:-}"

    if [[ -f "$cfg" ]]; then
        # shellcheck source=/dev/null
        source "$cfg"
    elif [[ -n "$CONFIG_FILE" || -n "${MERGE_CONFIG:-}" ]]; then
        echo "Error: config file '$cfg' not found." >&2
        exit 1
    fi

    # Config-file values (MERGE_* now holds them after the source), then
    # environment variables override them.  if-statements (not `[[ ]] &&
    # x=` chains): a false test must leave the function returning 0, or
    # set -e kills the caller.
    if [[ -n "${MERGE_SOURCE_DIR:-}" ]]; then
        SOURCE_DIR="$MERGE_SOURCE_DIR"
    fi
    if [[ -n "${MERGE_SKELETON_ROOT:-}" ]]; then
        SKELETON_ROOT="$MERGE_SKELETON_ROOT"
    fi
    if [[ -n "${MERGE_REPORT_DIR:-}" ]]; then
        REPORT_DIR="$MERGE_REPORT_DIR"
    fi
    if [[ -n "${MERGE_RECURSIVE:-}" ]]; then
        RECURSIVE="$(merge_normalize_bool "$MERGE_RECURSIVE")"
    fi
    if [[ -n "${MERGE_OVERWRITE:-}" ]]; then
        OVERWRITE_POLICY="$(merge_normalize_overwrite "$MERGE_OVERWRITE")"
    fi

    if [[ -n "$env_source" ]]; then
        SOURCE_DIR="$env_source"
    fi
    if [[ -n "$env_skeleton" ]]; then
        SKELETON_ROOT="$env_skeleton"
    fi
    if [[ -n "$env_report" ]]; then
        REPORT_DIR="$env_report"
    fi
    if [[ -n "$env_recursive" ]]; then
        RECURSIVE="$(merge_normalize_bool "$env_recursive")"
    fi
    if [[ -n "${MERGE_SKIP_NAMES:-}" ]]; then
        SKIP_NAMES="$MERGE_SKIP_NAMES"
    fi
    if [[ -n "$env_skip_names" ]]; then
        SKIP_NAMES="$env_skip_names"
    fi
    if [[ -n "$env_overwrite" ]]; then
        OVERWRITE_POLICY="$(merge_normalize_overwrite "$env_overwrite")"
    fi
}

# -----------------------------------------------------------------------------
# merge_load_skip_names
# -----------------------------------------------------------------------------
# Split the SKIP_NAMES string into the SKIP_NAME_ARRAY used for matching.
# Called after configuration is resolved (config value, then env override).
# -----------------------------------------------------------------------------
merge_load_skip_names() {
    local name
    SKIP_NAME_ARRAY=()
    for name in $SKIP_NAMES; do
        [[ -n "$name" ]] && SKIP_NAME_ARRAY+=("${name,,}")
    done
}

# -----------------------------------------------------------------------------
# merge_is_skipped_name
# -----------------------------------------------------------------------------
# Return 0 when a basename is on the skip list (case-insensitive).  Used to
# keep Windows metadata files like desktop.ini / Thumbs.db out of the
# library entirely.
# -----------------------------------------------------------------------------
merge_is_skipped_name() {
    local base="${1,,}" name
    for name in "${SKIP_NAME_ARRAY[@]}"; do
        [[ "$base" == "$name" ]] && return 0
    done
    return 1
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
#   $1 - status: copied|would-copy|overwritten|duplicate|duplicate-name|
#                collision|unmatched-author|ambiguous-author|skipped
#   $2 - human-readable reason
#   $3 - source author name
#   $4 - source file (relative to the author folder, or "-")
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
        copied|would-copy|overwritten) ;;
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
# merge_should_overwrite
# -----------------------------------------------------------------------------
# Decide, per OVERWRITE_POLICY, whether an existing destination file may be
# replaced.  In 'ask' mode a non-interactive stdin behaves like 'never' so
# a scripted run can never hang on a prompt.
#
# Arguments:
#   $1 - author name (for the prompt)
#   $2 - relative source file (for the prompt)
# Returns 0 when overwriting is allowed, 1 otherwise.
# -----------------------------------------------------------------------------
merge_should_overwrite() {
    local author="$1" src="$2" answer

    case "$OVERWRITE_POLICY" in
        force)
            return 0
            ;;
        never)
            return 1
            ;;
        ask)
            if [[ ! -t 0 ]]; then
                return 1
            fi
            printf 'Overwrite %s: %s? [y/N] ' "$author" "$src" >&2
            IFS= read -r answer
            case "${answer,,}" in
                y|yes) return 0 ;;
                *) return 1 ;;
            esac
            ;;
    esac
}

# -----------------------------------------------------------------------------
# merge_copy_file
# -----------------------------------------------------------------------------
# Copy one source file into its resolved destination, applying the
# duplicate/collision detection and the overwrite policy.
#
# Arguments:
#   $1 - author name
#   $2 - absolute source path
#   $3 - source file relative to the author folder (for reporting)
#   $4 - absolute destination path
# -----------------------------------------------------------------------------
merge_copy_file() {
    local author="$1" src="$2" rel="$3" target="$4"
    local dest_rel="${target#"$SKELETON_ROOT"/}"
    local status reason

    # Windows metadata files (desktop.ini, Thumbs.db, ...) are never copied.
    if merge_is_skipped_name "${rel##*/}"; then
        merge_record "skipped" "Windows metadata file (skip list)" \
            "$author" "$rel" "$dest_rel"
        return
    fi

    if [[ -e "$target" ]]; then
        # A destination written earlier THIS run by a different source is a
        # collision; the same source twice is a true duplicate; anything
        # else pre-existed on disk (duplicate-name).  Only collisions and
        # pre-existing files are subject to the overwrite policy -- a true
        # duplicate of the same source is always skipped.
        if [[ -n "${DEST_SOURCE[$target]:-}" ]]; then
            if [[ "${DEST_SOURCE[$target]}" == "$src" ]]; then
                status="duplicate"
                reason="same source file copied twice"
            else
                status="collision"
                reason="destination name already written this run by ${DEST_SOURCE[$target]##*/}"
            fi
        else
            status="duplicate-name"
            reason="a file with this name already exists at the destination"
        fi

        if [[ "$status" != "duplicate" ]] && merge_should_overwrite "$author" "$rel"; then
            if [[ "$DRY_RUN" == true ]]; then
                DEST_SOURCE[$target]="$src"
                merge_record "would-copy" \
                    "dry run: would overwrite (policy $OVERWRITE_POLICY)" \
                    "$author" "$rel" "$dest_rel"
            else
                if cp -p -- "$src" "$target"; then
                    DEST_SOURCE[$target]="$src"
                    merge_record "overwritten" \
                        "overwrite policy: $OVERWRITE_POLICY" \
                        "$author" "$rel" "$dest_rel"
                else
                    merge_record "skipped" "copy failed" \
                        "$author" "$rel" "$dest_rel"
                fi
            fi
            return
        fi

        merge_record "$status" "$reason" "$author" "$rel" "$dest_rel"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        DEST_SOURCE[$target]="$src"
        merge_record "would-copy" "dry run: no files were copied" \
            "$author" "$rel" "$dest_rel"
        return
    fi

    mkdir -p -- "$(dirname "$target")"
    if cp -p -- "$src" "$target"; then
        DEST_SOURCE[$target]="$src"
        merge_record "copied" "" "$author" "$rel" "$dest_rel"
    else
        merge_record "skipped" "copy failed" "$author" "$rel" "$dest_rel"
    fi
}

# -----------------------------------------------------------------------------
# merge_record_unmatched
# -----------------------------------------------------------------------------
# Record every direct child of an author folder whose destination could not
# be resolved (unmatched or ambiguous).  Nothing is copied.
# -----------------------------------------------------------------------------
merge_record_unmatched() {
    local status="$1" reason="$2" author_dir="$3"
    local author="${author_dir##*/}"
    local -a children=()
    local child

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
}

# -----------------------------------------------------------------------------
# merge_process_author
# -----------------------------------------------------------------------------
# Resolve one top-level source author folder and copy its files.  With
# RECURSIVE on, every file at any depth is copied and the relative layout
# (book series folders) is preserved; empty subfolders are never created.
# With RECURSIVE off, only direct files are copied and subfolders are
# recorded as skipped.
# -----------------------------------------------------------------------------
merge_process_author() {
    local author_dir="$1"
    local author="${author_dir##*/}"
    local child rel target

    # Trim surrounding whitespace from the folder name for lookup/reporting.
    author="${author#"${author%%[![:space:]]*}"}"
    author="${author%"${author##*[![:space:]]}"}"

    if [[ -z "$author" || "$author" == "." || "$author" == ".." ]]; then
        return
    fi

    if ! merge_find_dest "$author"; then
        local status="unmatched-author"
        local reason="no skeleton prefix matches the author name"
        if [[ "$MATCH_AMBIGUOUS" == true ]]; then
            status="ambiguous-author"
            reason="several skeleton paths share the longest matching prefix"
        fi
        merge_record_unmatched "$status" "$reason" "$author_dir"
        return
    fi

    # The author becomes its own directory under the deepest matching prefix,
    # so authors that share a prefix never collide their books together.  If
    # the matched prefix is already the author's own name, it IS that folder
    # (created earlier, or a pre-built one) -- do not append it a second time.
    local dest_dir
    if [[ "${MATCH_DEST##*/}" == "$author" ]]; then
        dest_dir="$SKELETON_ROOT/$MATCH_DEST"
    else
        dest_dir="$SKELETON_ROOT/$MATCH_DEST/$author"
    fi

    if [[ "$RECURSIVE" == true ]]; then
        # Every regular file at any depth; empty folders never appear.
        while IFS= read -r child; do
            rel="${child#"$author_dir"/}"
            target="$dest_dir/$rel"
            merge_copy_file "$author" "$child" "$rel" "$target"
        done < <(find "$author_dir" -type f | LC_ALL=C sort)
    else
        # Direct files only; subfolders (book series) are skipped.
        while IFS= read -r child; do
            if [[ -d "$child" ]]; then
                merge_record "skipped" "nested folder (recursive copy disabled)" \
                    "$author" "${child##*/}" "-"
                continue
            fi
            if [[ ! -f "$child" ]]; then
                merge_record "skipped" "not a regular file" \
                    "$author" "${child##*/}" "-"
                continue
            fi
            rel="${child##*/}"
            target="$dest_dir/$rel"
            merge_copy_file "$author" "$child" "$rel" "$target"
        done < <(find "$author_dir" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
    fi
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
# Program entry point: load configuration, parse, validate, collect the
# skeleton, process every author folder, and print a summary.
# -----------------------------------------------------------------------------
merge_main() {
    merge_find_config "$@"
    merge_load_config
    merge_parse_args "$@"

    OVERWRITE_POLICY="$(merge_normalize_overwrite "$OVERWRITE_POLICY")"
    merge_load_skip_names

    if [[ -z "$SOURCE_DIR" ]]; then
        echo "Error: no source directory given (--source or MERGE_SOURCE_DIR)." >&2
        merge_usage
        exit 1
    fi
    if [[ -z "$SKELETON_ROOT" ]]; then
        echo "Error: no skeleton directory given (--skeleton or MERGE_SKELETON_ROOT)." >&2
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
    echo "  recursive: $RECURSIVE   overwrite: $OVERWRITE_POLICY"
    echo "  skip:     ${SKIP_NAMES:-<none>}"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  mode:     DRY RUN - nothing will be copied"
    fi

    local author_dir authors=0
    while IFS= read -r author_dir; do
        merge_process_author "$author_dir"
        authors=$((authors + 1))
    done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

    # Summary counts, derived from the manifest rows (excluding the header).
    local total copied dup dupname coll unmatched amb overwritten skipped
    total="$(awk 'NR>1 {n++} END{print n+0}' "$MANIFEST")"
    copied="$(awk -F '\t' 'NR>1 && $5=="copied" {n++} END{print n+0}' "$MANIFEST")"
    overwritten="$(awk -F '\t' 'NR>1 && $5=="overwritten" {n++} END{print n+0}' "$MANIFEST")"
    dup="$(awk -F '\t' 'NR>1 && $5=="duplicate" {n++} END{print n+0}' "$MANIFEST")"
    dupname="$(awk -F '\t' 'NR>1 && $5=="duplicate-name" {n++} END{print n+0}' "$MANIFEST")"
    coll="$(awk -F '\t' 'NR>1 && $5=="collision" {n++} END{print n+0}' "$MANIFEST")"
    unmatched="$(awk -F '\t' 'NR>1 && $5=="unmatched-author" {n++} END{print n+0}' "$MANIFEST")"
    amb="$(awk -F '\t' 'NR>1 && $5=="ambiguous-author" {n++} END{print n+0}' "$MANIFEST")"
    skipped="$(awk -F '\t' 'NR>1 && $5=="skipped" {n++} END{print n+0}' "$MANIFEST")"

    echo ""
    echo "authors: $authors   records: $total"
    echo "  copied: $copied   overwritten: $overwritten"
    echo "  duplicate: $dup   duplicate-name: $dupname   collision: $coll"
    echo "  unmatched: $unmatched   ambiguous: $amb   skipped: $skipped"
    echo "reports written to $REPORT_DIR"
}
