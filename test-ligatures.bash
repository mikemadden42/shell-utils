#!/bin/bash

# Define the symbols to test
symbols=("==" "!=" "===" "!==" "=>" "=>>" ">=" "<=" "->" "<-" "&&" "||" "###" "///" "/*" "*/" "::")

echo -e "\033[1;35mWezTerm Font Rendering Test\033[0m"
printf "%-15s | %-15s | %-15s\n" "Symbol" "Raw (Spaced)" "Ligature (Joined)"
echo "------------------------------------------------------------"

for s in "${symbols[@]}"; do
	# SC2001 Fix: Use Bash Parameter Expansion instead of sed
	# This takes every character (represented by ?) and adds a space after it
	# We use a temporary variable to handle the expansion safely
	spaced=""
	for ((i = 0; i < ${#s}; i++)); do
		spaced+="${s:$i:1} "
	done

	# Print the table row
	printf "  %-13s | %-15s | \033[1;32m%s\033[0m\n" "$s" "$spaced" "$s"
done

echo "------------------------------------------------------------"
echo -e "\033[1;33mVisual Check:\033[0m"
echo "If the green symbols look like custom icons (e.g., != becomes a single glyph"
echo "with a slash through it), your font ligatures are working perfectly."
