#!/bin/bash

# 1. Validate that an argument was passed and that the file exists
if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_word_list_file>" >&2
    exit 1
fi

INPUT_FILE="$1"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: File '$INPUT_FILE' not found." >&2
    exit 1
fi

# 2. Read words, trim carriage returns, and sort alphabetically
mapfile -t SORTED_WORDS < <(tr -d '\r' < "$INPUT_FILE" | grep -v '^$' | sort)

if [ ${#SORTED_WORDS[@]} -eq 0 ]; then
    echo "Error: File '$INPUT_FILE' is empty or contains no valid text." >&2
    exit 1
fi

# Initialize runtime tracking counter
COUNTER=1

# Initialize array stacks for depth tracking
stack_words=()
stack_lft=()

# Initialize an associative array buffer for finished rows
declare -A finished_nodes

# =====================================================================
# GENERATE SQL HEADER (SCHEMA IMPLEMENTATION & TRANSACTION START)
# =====================================================================
echo "DROP TABLE IF EXISTS \`dictionary_nested_set\`;"
echo "CREATE TABLE \`dictionary_nested_set\` ("
echo "    \`id\` INT AUTO_INCREMENT PRIMARY KEY,"
echo "    \`word\` VARCHAR(50) NOT NULL,"
echo "    \`lft\` INT NOT NULL,"
echo "    \`rgt\` INT NOT NULL,"
echo "    INDEX \`idx_lft_rgt\` (\`lft\`, \`rgt\`)"
echo ") ENGINE=MYISAM COLLATE=utf8_general_ci;"
echo ""
echo "START TRANSACTION;"
echo "INSERT INTO \`dictionary_nested_set\` (\`word\`, \`lft\`, \`rgt\`) VALUES"

# 3. Depth-first evaluation loop
for current_word in "${SORTED_WORDS[@]}"; do

    # Close nodes that are no longer a prefix match
    while [ ${#stack_words[@]} -gt 0 ]; do
        last_index=$((${#stack_words[@]} - 1))
        stack_word="${stack_words[$last_index]}"
        
        # Check if the incoming word is a descendant
        if [[ "$current_word" == "$stack_word"* ]]; then
            break
        fi

        # POP ACTION: Close the current branch path
        parent_word="${stack_words[$last_index]}"
        parent_lft="${stack_lft[$last_index]}"
        
        finished_nodes["$parent_lft"]="$parent_word,$parent_lft,$COUNTER"
        
        COUNTER=$((COUNTER + 1))
        unset 'stack_words[$last_index]'
        unset 'stack_lft[$last_index]'
        
        stack_words=("${stack_words[@]}")
        stack_lft=("${stack_lft[@]}")
    done

    # PUSH ACTION: Register the word to the tracking arrays
    stack_words+=("$current_word")
    stack_lft+=("$COUNTER")
    
    COUNTER=$((COUNTER + 1))
done

# 4. Flush remaining stacked parents
while [ ${#stack_words[@]} -gt 0 ]; do
    last_index=$((${#stack_words[@]} - 1))
    
    parent_word="${stack_words[$last_index]}"
    parent_lft="${stack_lft[$last_index]}"
    
    finished_nodes["$parent_lft"]="$parent_word,$parent_lft,$COUNTER"
    
    COUNTER=$((COUNTER + 1))
    unset 'stack_words[$last_index]'
    unset 'stack_lft[$last_index]'
    
    stack_words=("${stack_words[@]}")
    stack_lft=("${stack_lft[@]}")
done

# =====================================================================
# GENERATE SQL INSERT VALUES AND FOOTER
# =====================================================================
# Sort the entries numerically by left value to format the SQL smoothly
sorted_lfts=($(printf '%s\n' "${!finished_nodes[@]}" | sort -n))
total_elements=${#sorted_lfts[@]}

for ((i=0; i<total_elements; i++)); do
    lft="${sorted_lfts[$i]}"
    line="${finished_nodes[$lft]}"
    
    # Split CSV line data back out to escape for SQL safely
    IFS=',' read -r word col_lft col_rgt <<< "$line"
    
    # Escape quotes inside words if any exist
    clean_word="${word//\'/\'\'}"
    
    # Use a comma delimiter for all lines EXCEPT the final trailing record
    if [ $((i + 1)) -eq $total_elements ]; then
        echo "    ('$clean_word', $col_lft, $col_rgt);"
    else
        echo "    ('$clean_word', $col_lft, $col_rgt),"
    fi
done

echo "COMMIT;"
