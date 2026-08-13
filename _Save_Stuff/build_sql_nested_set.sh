#!/usr/bin/env bash

###############################################################################
# build_sql_nested_set.sh
#
# Creates SQL statements for a nested-set representation of an author list.
#
# Usage:
#   ./build_sql_nested_set.sh --input-file=authors_list_from_db.txt
#
# Supported argument formats:
#   --input-file=FILE
#   --input-file FILE
#   --input-file = FILE
#   --input-file =FILE
#   -i=FILE
#   -i FILE
#   -i = FILE
#   -i =FILE
# Version: V02
# The script reads author names from the input file, builds a nested-set
# hierarchy using prefix relationships between sorted author names, and
# generates SQL statements for the dictionary_nested_set table.
###############################################################################

# ====================== Usage Information ======================

usage() {
    echo "Usage: $0 --input-file=FILE [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -i, --input-file=FILE  Path to the file containing author names (one per line)"
    echo ""
    echo "Optional:"
    echo "  -h, --help             Show this help message"
    exit 1
}

# ====================== Configuration & Defaults ======================

INPUT_FILE=""

# ====================== Parse Command-Line Arguments ======================

parse_cli_args() {
    local -a PREPARED_ARGS=()
    local FLAG
    local VALUE

    # Normalize argument formats before standard parsing.
    #
    # Supported forms include:
    #   --input-file=FILE
    #   --input-file FILE
    #   --input-file = FILE
    #   --input-file =FILE
    #   -i=FILE
    #   -i FILE
    #   -i = FILE
    #   -i =FILE

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --input-file=*|-i=*)
                FLAG="${1%%=*}"
                VALUE="${1#*=}"

                if [[ -z "$VALUE" ]]; then
                    if [[ $# -lt 2 ]]; then
                        echo "Error: $FLAG requires a value." >&2
                        exit 1
                    fi

                    VALUE="$2"
                    shift
                fi

                PREPARED_ARGS+=("$FLAG" "$VALUE")
                ;;

            --input-file|-i)
                if [[ $# -lt 2 ]]; then
                    echo "Error: $1 requires a value." >&2
                    exit 1
                fi

                if [[ "$2" == "=" ]]; then
                    if [[ $# -lt 3 ]]; then
                        echo "Error: $1 requires a value." >&2
                        exit 1
                    fi

                    PREPARED_ARGS+=("$1" "$3")
                    shift 2

                elif [[ "$2" == =* ]]; then
                    PREPARED_ARGS+=("$1" "${2#=}")
                    shift

                else
                    PREPARED_ARGS+=("$1" "$2")
                    shift
                fi
                ;;

            -h|--help)
                PREPARED_ARGS+=("$1")
                ;;

            *)
                if [[ "$1" != "=" ]]; then
                    PREPARED_ARGS+=("$1")
                fi
                ;;
        esac

        shift
    done

    set -- "${PREPARED_ARGS[@]}"

    # Parse normalized arguments.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--input-file)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: $1 requires a value." >&2
                    exit 1
                fi

                INPUT_FILE="$2"
                shift 2
                ;;

            -h|--help)
                usage
                ;;

            *)
                echo "Error: Unexpected option or argument '$1'." >&2
                usage
                ;;
        esac
    done
}

# ====================== Validate Input ======================

validate_input_file() {
    if [[ -z "$INPUT_FILE" ]]; then
        echo "Error: --input-file is required." >&2
        usage
    fi

    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "Error: File '$INPUT_FILE' does not exist." >&2
        exit 1
    fi

    INPUT_FILE="$(cd "$(dirname "$INPUT_FILE")" && pwd)/$(basename "$INPUT_FILE")"

    if [[ ! -r "$INPUT_FILE" ]]; then
        echo "Error: File '$INPUT_FILE' is not readable." >&2
        exit 1
    fi
}

# ====================== Load and Sort Authors ======================

load_authors() {
    mapfile -t SORTED_AUTHORS < <(
        tr -d '\r' < "$INPUT_FILE" |
        grep -v '^$' |
        sort
    )

    if [[ ${#SORTED_AUTHORS[@]} -eq 0 ]]; then
        echo "Error: File '$INPUT_FILE' is empty or contains no valid text." >&2
        exit 1
    fi
}

# ====================== Initialize Nested-Set Data ======================

initialize_nested_set() {
    COUNTER=1

    STACK_AUTHORS=()
    STACK_LFT=()

    declare -gA FINISHED_NODES=()
}

# ====================== Close Current Nested-Set Node ======================

close_nested_set_node() {
    local LAST_INDEX
    local AUTHOR
    local LFT

    LAST_INDEX=$((${#STACK_AUTHORS[@]} - 1))

    AUTHOR="${STACK_AUTHORS[$LAST_INDEX]}"
    LFT="${STACK_LFT[$LAST_INDEX]}"

    FINISHED_NODES["$LFT"]="$AUTHOR,$LFT,$COUNTER"

    COUNTER=$((COUNTER + 1))

    unset 'STACK_AUTHORS[$LAST_INDEX]'
    unset 'STACK_LFT[$LAST_INDEX]'

    STACK_AUTHORS=("${STACK_AUTHORS[@]}")
    STACK_LFT=("${STACK_LFT[@]}")
}

# ====================== Build Nested-Set Structure ======================

build_nested_set() {
    local CURRENT_AUTHOR
    local LAST_INDEX
    local STACK_AUTHOR

    for CURRENT_AUTHOR in "${SORTED_AUTHORS[@]}"; do

        # Close nodes that are no longer prefixes of the current author.
        while [[ ${#STACK_AUTHORS[@]} -gt 0 ]]; do
            LAST_INDEX=$((${#STACK_AUTHORS[@]} - 1))
            STACK_AUTHOR="${STACK_AUTHORS[$LAST_INDEX]}"

            # The current author remains inside the current hierarchy branch.
            if [[ "$CURRENT_AUTHOR" == "$STACK_AUTHOR"* ]]; then
                break
            fi

            close_nested_set_node
        done

        # Open the current author node.
        STACK_AUTHORS+=("$CURRENT_AUTHOR")
        STACK_LFT+=("$COUNTER")

        COUNTER=$((COUNTER + 1))
    done

    # Close all nodes remaining on the stack.
    while [[ ${#STACK_AUTHORS[@]} -gt 0 ]]; do
        close_nested_set_node
    done
}

# ====================== Generate SQL Header ======================

generate_sql_header() {
    echo 'DROP TABLE IF EXISTS `dictionary_nested_set`;'
    echo 'CREATE TABLE `dictionary_nested_set` ('
    echo '    `id` INT AUTO_INCREMENT PRIMARY KEY,'
    echo '    `word` VARCHAR(50) NOT NULL,'
    echo '    `lft` INT NOT NULL,'
    echo '    `rgt` INT NOT NULL,'
    echo '    INDEX `idx_lft_rgt` (`lft`, `rgt`)'
    echo ') ENGINE=MYISAM COLLATE=utf8_general_ci;'
    echo ""
    echo 'START TRANSACTION;'
    echo 'INSERT INTO `dictionary_nested_set` (`word`, `lft`, `rgt`) VALUES'
}

# ====================== Generate SQL Rows ======================

generate_sql_rows() {
    local -a SORTED_LFTS
    local TOTAL_ELEMENTS
    local LFT
    local LINE
    local WORD
    local COL_LFT
    local COL_RGT
    local CLEAN_WORD
    local i

    SORTED_LFTS=(
        $(printf '%s\n' "${!FINISHED_NODES[@]}" | sort -n)
    )

    TOTAL_ELEMENTS=${#SORTED_LFTS[@]}

    for ((i = 0; i < TOTAL_ELEMENTS; i++)); do
        LFT="${SORTED_LFTS[$i]}"
        LINE="${FINISHED_NODES[$LFT]}"

        IFS=',' read -r WORD COL_LFT COL_RGT <<< "$LINE"

        # Escape single quotes for SQL string literals.
        CLEAN_WORD="${WORD//\'/\'\'}"

        if [[ $((i + 1)) -eq TOTAL_ELEMENTS ]]; then
            echo "    ('$CLEAN_WORD', $COL_LFT, $COL_RGT);"
        else
            echo "    ('$CLEAN_WORD', $COL_LFT, $COL_RGT),"
        fi
    done
}

# ====================== Generate SQL Footer ======================

generate_sql_footer() {
    echo "COMMIT;"
}

# ====================== Main ======================

main() {
    parse_cli_args "$@"
    validate_input_file
    load_authors
    initialize_nested_set
    generate_sql_header
    build_nested_set
    generate_sql_rows
    generate_sql_footer
}

main "$@"

