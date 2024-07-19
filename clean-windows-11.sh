#!/bin/sh

# Define directories
directories="Desktop Documents Downloads Movies Music Pictures"

# Loop through each directory
for d in $directories; do
	# Check if the directory exists
	if [ -d "$d" ]; then
		# Remove specific files
		[ -f "$d/desktop.ini" ] && rm "$d/desktop.ini"
		# Remove specific directories
		[ -d "$d/\$RECYCLE.BIN" ] && rm -rf "$d/\$RECYCLE.BIN"
	fi
done

# Remove a specific file, if it exists
[ -f "Desktop/Windows 11" ] && unlink "Desktop/Windows 11"
