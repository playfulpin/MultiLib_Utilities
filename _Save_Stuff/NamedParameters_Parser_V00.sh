#!/usr/bin/env bash

###############################################################################
# build_shell_nested_authors.sh
#
# Creates a nested directory hierarchy for authors based on name prefixes.
# Only the deepest valid prefix per branch is created (mkdir -p handles parents).
#
# Usage:
#   ./build_shell_nested_authors.sh --input-file=authors.txt [--min-authors=10] [--max-prefix=5]
#
# Author: 
# Version: 2.0 (with named arguments)
###############################################################################

# Print usage information
usage() {
    echo "Usage: $0 --input-file=FILE [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -i, --input-file=FILE  Path to the file containing author names (one per line)"
    echo ""
    echo "Optional:"
    echo "  -m, --min-authors=NUM  Minimum number of authors required for a prefix [default: 10]"
    echo "  -x, --max-prefix=NUM   Maximum length of prefix to consider [default: 5]"
    echo "  -h, --help             Show this help message"
    exit 1
}


# ====================== Configuration & Defaults ======================
ROOT_DIRECTORY="/mnt/c/Backup_Nova3/Empty_Skeleton"

# Default values
INPUT_FILE=""
MIN_AUTHORS=10
MAX_PREFIX=5

# ====================== Parse Named Arguments ======================
# --- STEP 1: Normalize Arguments (Handles spacing and '=' variations) ---
PREPARED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        # Case A: Combined formats with an equals sign inside them (--flag=value or -f=value)
        --input-file=*|-i=*|--min-authors=*|-m=*|--max-prefix=*|-x=*)
            flag="${1%%=*}"
            val="${1#*=}"
            # Handle '--flag= filename' (grab next argument if empty)
            if [[ -z "$val" ]]; then
                val="$2"
                shift
            fi
            PREPARED_ARGS+=("$flag" "$val")
            ;;

        # Case B: Isolated flags (--flag)
        --input-file|-i|--min-authors|-m|--max-prefix|-x)
            # If the next token is an isolated '=', skip it and grab the following token
            if [[ "$2" == "=" ]]; then
                PREPARED_ARGS+=("$1" "$3")
                shift 2
            # CRITICAL FIX: If next token starts with an equals sign (e.g., '=filename')
            elif [[ "$2" == =* ]]; then
                PREPARED_ARGS+=("$1" "${2#=}")
                shift 1
            # Standard space-separated format (--flag filename)
            else
                PREPARED_ARGS+=("$1" "$2")
                shift 1
            fi
            ;;

        -h|--help)
            PREPARED_ARGS+=("$1")
            ;;

        *)
            # Ignore a solitary, rogue '=' that might be lingering from variations
            if [[ "$1" != "=" ]]; then
                PREPARED_ARGS+=("$1")
            fi
            ;;
    esac
    shift
done

# Overwrite positional parameters with the cleaned array
set -- "${PREPARED_ARGS[@]}"

# --- STEP 2: Standard Argument Parser ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--input-file)
            INPUT_FILE="$2"
            shift 2
            ;;
        -m|--min-authors)
            if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --min-authors requires a numeric value." >&2
                exit 1
            fi
            MIN_AUTHORS="$2"
            shift 2
            ;;
        -x|--max-prefix)
            if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --max-prefix requires a numeric value." >&2
                exit 1
            fi
            MAX_PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unexpected option or argument '$1'" >&2
            usage
            ;;
    esac
done

# ====================== Validation ======================
if [[ -z "$INPUT_FILE" ]]; then
    echo "Error: --input-file is required." >&2
    usage
fi

# Convert to absolute path
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: File '$INPUT_FILE' does not exist." >&2
    exit 1
fi

INPUT_FILE="$(cd "$(dirname "$INPUT_FILE")" && pwd)/$(basename "$INPUT_FILE")"

if [[ ! -r "$INPUT_FILE" ]]; then
    echo "Error: File '$INPUT_FILE' is not readable." >&2
    exit 1
fi

if ! [[ "$MIN_AUTHORS" =~ ^[1-9][0-9]*$ ]] || \
   ! [[ "$MAX_PREFIX" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --min-authors and --max-prefix must be positive integers." >&2
    exit 1
fi

# ====================== Prepare Destination ======================