#!/usr/bin/env bash

###############################################################################
# build_shell_nested_authors.sh
#
# Generate "mkdir -p" commands for a nested author directory hierarchy.
#
# Input:
#   A list of author names, one author per line.
#
# Usage:
#
#   ./build_shell_nested_authors.sh \
#       <input_file> \
#       <minimum_authors> \
#       <maximum_prefix_length>
#
# Example:
#
#   ./build_shell_nested_authors.sh alphabet_from_db.txt 6 5
#
# Output:
#
#   cd /path/to/root
#   mkdir -p А/Аб/Абр/Абра
#
###############################################################################
# Algorithm
# ---------
#
# The input is sorted alphabetically and stored in SORTED_AUTHORS.
#
# The script builds a prefix tree in a single pass through the input.
#
# For every author:
#
#   1. Extract prefixes from length 1 through MAXIMUM_PREFIX_LENGTH.
#   2. Increment the author count associated with every prefix.
#
# Example:
#
#   Author:
#       Абрамов Александр Иванович
#
#   Prefixes:
#
#       А
#       Аб
#       Абр
#       Абра
#       Абрам
#
# After all authors are processed, every prefix has its total number of
# matching authors.
#
# A prefix is considered valid when:
#
#   matching_author_count >= MINIMUM_AUTHORS
#
# A valid prefix can be expanded into longer prefixes.
#
# If a prefix has fewer than MINIMUM_AUTHORS matching authors:
#
#   - The prefix is not created.
#   - The branch is not expanded further.
#
# Only the deepest valid prefix of each branch is printed.
#
# This is important because "mkdir -p" automatically creates all missing
# parent directories.
#
# Example with MINIMUM_AUTHORS=6:
#
#   А       20 authors -> valid
#   Аб      20 authors -> valid
#   Аба      3 authors -> stop
#   Абб      1 author  -> stop
#   Абв      1 author  -> stop
#   Абд      1 author  -> stop
#   Абе      2 authors -> stop
#   Абз      1 author  -> stop
#   Абн      1 author  -> stop
#   Або      1 author  -> stop
#   Абр      7 authors -> valid
#   Абра     7 authors -> valid
#   Абрам    5 authors -> stop
#   Абрах    1 author  -> stop
#   Абэ      1 author  -> stop
#
# Result:
#
#   mkdir -p А/Аб/Абр/Абра
#
# The parent directories А, Аб and Абр are not printed separately because
# "mkdir -p А/Аб/Абр/Абра" creates them automatically.
#
###############################################################################

###############################################################################
# Configuration
###############################################################################

readonly ROOT_DIRECTORY="/mnt/c/Backup_Nova3/Empty_Skeleton"

###############################################################################
# Validate command-line arguments
###############################################################################

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <path_to_author_list_file> <minimum_authors> <maximum_prefix_length>" >&2
    exit 1
fi

readonly INPUT_FILE="$1"
readonly MINIMUM_AUTHORS="$2"
readonly MAXIMUM_PREFIX_LENGTH="$3"

###############################################################################
# Validate input file
###############################################################################

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: File '$INPUT_FILE' not found." >&2
    exit 1
fi

###############################################################################
# Validate numeric arguments
###############################################################################

if ! [[ "$MINIMUM_AUTHORS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: minimum_authors must be a positive integer." >&2
    exit 1
fi

if ! [[ "$MAXIMUM_PREFIX_LENGTH" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: maximum_prefix_length must be a positive integer." >&2
    exit 1
fi

###############################################################################
# Read, normalize and sort the input.
#
# The input is:
#
#   - Read from INPUT_FILE.
#   - Converted from Windows CRLF to Unix LF by removing carriage returns.
#   - Empty lines are removed.
#   - Sorted alphabetically.
###############################################################################

mapfile -t SORTED_AUTHORS < <(
    tr -d '\r' < "$INPUT_FILE" |
    grep -v '^$' |
    sort
)

readonly TOTAL_AUTHORS=${#SORTED_AUTHORS[@]}

if (( TOTAL_AUTHORS == 0 )); then
    echo "Error: Input file contains no valid authors." >&2
    exit 1
fi

###############################################################################
# Prepare the destination directory.
###############################################################################

mkdir -p "$ROOT_DIRECTORY"

if ! cd "$ROOT_DIRECTORY"; then
    echo "Error: Unable to change directory to '$ROOT_DIRECTORY'." >&2
    exit 1
fi

echo "cd $ROOT_DIRECTORY"

###############################################################################
# Prefix author count table.
#
# Each key represents a prefix.
#
# Example:
#
#   prefix_author_count["А"]     = 20
#   prefix_author_count["Аб"]    = 20
#   prefix_author_count["Абр"]   = 7
#   prefix_author_count["Абра"]  = 7
#   prefix_author_count["Абрам"] = 5
#
###############################################################################

declare -A prefix_author_count=()

###############################################################################
# Build the prefix author count table.
#
# Each author contributes one count to every prefix up to
# MAXIMUM_PREFIX_LENGTH.
#
# Example:
#
#   Author:
#       Абрамов
#
#   Updates:
#
#       А     +1
#       Аб    +1
#       Абр   +1
#       Абра  +1
#       Абрам +1
###############################################################################

for current_author in "${SORTED_AUTHORS[@]}"
do
    ###########################################################################
    # Do not process more characters than either:
    #
    #   1. The author name contains, or
    #   2. MAXIMUM_PREFIX_LENGTH allows.
    ###########################################################################

    if (( ${#current_author} < MAXIMUM_PREFIX_LENGTH )); then
        maximum_author_prefix_length=${#current_author}
    else
        maximum_author_prefix_length=$MAXIMUM_PREFIX_LENGTH
    fi

    ###########################################################################
    # Add the author to the count of every applicable prefix.
    ###########################################################################

    for (( prefix_length=1;
           prefix_length<=maximum_author_prefix_length;
           prefix_length++ ))
    do
        current_prefix="${current_author:0:prefix_length}"

        (( prefix_author_count["$current_prefix"]++ ))
    done
done

###############################################################################
# Build the directory path from a prefix.
#
# Arguments:
#   $1 - Current prefix.
#
# Example:
#
#   Input:
#       Абра
#
#   Output:
#       А/Аб/Абр/Абра
#
###############################################################################

build_directory_path()
{
    local current_prefix="$1"
    local directory_components=()
    local prefix_length

    ###########################################################################
    # Build each prefix component.
    #
    # Example:
    #
    #   Абра
    #
    #   Components:
    #
    #       А
    #       Аб
    #       Абр
    #       Абра
    ###########################################################################

    for (( prefix_length=1;
           prefix_length<=${#current_prefix};
           prefix_length++ ))
    do
        directory_components+=(
            "${current_prefix:0:prefix_length}"
        )
    done

    ###########################################################################
    # Join the components with "/".
    ###########################################################################

    local IFS="/"

    printf '%s' "${directory_components[*]}"
}

###############################################################################
# Process a prefix recursively.
#
# Arguments:
#   $1 - Current prefix.
#
# The current prefix is valid when it contains at least MINIMUM_AUTHORS
# matching authors.
#
# The function continues recursively into valid child prefixes.
#
# The current prefix is printed only when:
#
#   1. MAXIMUM_PREFIX_LENGTH has been reached, or
#   2. There are no valid child prefixes.
#
# This ensures that only the deepest valid directory of each branch is
# printed.
#
# Example:
#
#   А       20 -> valid
#   Аб      20 -> valid
#   Абр      7 -> valid
#   Абра     7 -> valid
#   Абрам    5 -> invalid
#
# Output:
#
#   mkdir -p А/Аб/Абр/Абра
#
###############################################################################

process_prefix()
{
    local current_prefix="$1"
    local matching_author_count
    local directory_path
    local next_prefix
    local next_character
    local current_author
    local previous_next_character=""
    local has_valid_child=false

    ###########################################################################
    # Look up the number of authors associated with the current prefix.
    #
    # The prefix count was calculated once during the initial processing phase.
    # Therefore, this lookup is much faster than scanning all authors again.
    ###########################################################################

    matching_author_count=${prefix_author_count["$current_prefix"]:-0}

    ###########################################################################
    # Stop processing this branch when there are not enough matching authors.
    #
    # Every child prefix can only contain the same or fewer authors than its
    # parent prefix. Therefore, no descendant can become valid after the
    # current prefix becomes invalid.
    ###########################################################################

    if (( matching_author_count < MINIMUM_AUTHORS )); then
        return
    fi

    ###########################################################################
    # Stop expanding when the maximum prefix length has been reached.
    #
    # The current prefix is therefore the deepest possible valid prefix.
    ###########################################################################

    if (( ${#current_prefix} >= MAXIMUM_PREFIX_LENGTH )); then
        directory_path=$(build_directory_path "$current_prefix")

        echo "mkdir -p $directory_path"

        return
    fi

    ###########################################################################
    # Find child prefixes.
    #
    # Because SORTED_AUTHORS is sorted alphabetically, authors with the same
    # next character occur together.
    #
    # Each unique next character identifies one child prefix.
    ###########################################################################

    for current_author in "${SORTED_AUTHORS[@]}"
    do
        #######################################################################
        # Skip authors that do not belong to the current prefix.
        #######################################################################

        if [[ "$current_author" != "$current_prefix"* ]]; then
            continue
        fi

        #######################################################################
        # Skip authors that do not have another character after the prefix.
        #######################################################################

        if (( ${#current_author} <= ${#current_prefix} )); then
            continue
        fi

        #######################################################################
        # Extract the next character after the current prefix.
        #######################################################################

        next_character="${current_author:${#current_prefix}:1}"

        #######################################################################
        # The input is sorted, so identical next characters occur together.
        # Process each child prefix only once.
        #######################################################################

        if [[ "$next_character" == "$previous_next_character" ]]; then
            continue
        fi

        previous_next_character="$next_character"

        next_prefix="${current_prefix}${next_character}"

        #######################################################################
        # Check whether the child prefix has enough authors to continue.
        #######################################################################

        matching_author_count=${prefix_author_count["$next_prefix"]:-0}

        if (( matching_author_count < MINIMUM_AUTHORS )); then
            continue
        fi

        #######################################################################
        # At least one valid child exists.
        #
        # This means the current prefix must NOT be printed. The child branch
        # will produce the final "mkdir -p" command instead.
        #######################################################################

        has_valid_child=true

        #######################################################################
        # Continue recursively into the valid child.
        #######################################################################

        process_prefix "$next_prefix"
    done

    ###########################################################################
    # If no valid child exists, the current prefix is the deepest valid
    # directory for this branch.
    #
    # Print only this directory.
    #
    # "mkdir -p" automatically creates all required parent directories.
    ###########################################################################

    if [[ "$has_valid_child" == false ]]; then
        directory_path=$(build_directory_path "$current_prefix")

        echo "mkdir -p $directory_path"
    fi
}

###############################################################################
# Start processing.
#
# Extract each unique first character from SORTED_AUTHORS and use it as the
# root of a prefix tree.
###############################################################################

previous_root_character=""

for current_author in "${SORTED_AUTHORS[@]}"
do
    ###########################################################################
    # Ignore empty authors.
    ###########################################################################

    if [[ -z "$current_author" ]]; then
        continue
    fi

    ###########################################################################
    # Extract the first character of the author name.
    ###########################################################################

    current_prefix="${current_author:0:1}"

    ###########################################################################
    # The input is sorted, so identical first characters occur together.
    # Process each root prefix only once.
    ###########################################################################

    if [[ "$current_prefix" == "$previous_root_character" ]]; then
        continue
    fi

    previous_root_character="$current_prefix"

    ###########################################################################
    # Process the root prefix.
    ###########################################################################

    process_prefix "$current_prefix"
done