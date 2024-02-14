#!/bin/bash

for dir in */; do
	# Exclude the "." and ".." directories explicitly
	if [[ "$dir" != "." && "$dir" != ".." ]]; then
		# Extract the directory name, replacing spaces with dashes
		tarball_name=$(basename "$dir" | tr ' ' '-')

		# Create the tarball with compression and verbose output
		tar -czvf "$HOME/${tarball_name}.tar.gz" "$dir"
	fi
done
