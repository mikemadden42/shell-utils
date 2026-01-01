#!/bin/bash

# Define the symbols to test
symbols=("==" "!=" "===" "!==" "=>" "=>>" ">=" "<=" "->" "<-" "&&" "||" "###" "///" "/*" "*/" "::")

echo -e "\033[1;35mWezTerm Font Rendering Test\033[0m"
printf "%-15s | %-15s | %-15s\n" "Symbol" "Raw (Spaced)" "Ligature (Joined)"
echo "------------------------------------------------------------"

for s in "${symbols[@]}"; do
	# Split the string into characters separated by spaces
	# Example: '!=' becomes '! ='
	spaced=$(echo "$s" | sed 's/./& /g')

	# Print the table row
	printf "  %-13s | %-15s | \033[1;32m%s\033[0m\n" "$s" "$spaced" "$s"
done

echo "------------------------------------------------------------"
echo -e "\033[1;33mVisual Check:\033[0m"
echo "1. If 'Ligature' looks different than 'Raw', your font supports ligatures."
echo "2. If they look identical (just closer together), ligatures are OFF."
