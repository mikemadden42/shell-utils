#!/bin/bash

# Function to log messages with a UTC timestamp
log_step() {
	echo "[$(date -u +'%Y-%m-%d %H:%M:%S UTC')] $1"
}

# 1. Check for the CLI argument
if [ -z "$1" ]; then
	echo "Error: Target directory not provided."
	echo "Usage: $0 <target_directory>"
	exit 1
fi

TARGET_DIR="$1"

# Verify the provided directory actually exists
if [ ! -d "$TARGET_DIR" ]; then
	log_step "Error: Directory '$TARGET_DIR' does not exist."
	exit 1
fi

# Arrays to keep track of the exactly what we create for safe cleanup
CREATED_FILES=()
CREATED_DIRS=()

log_step "Starting operations in directory: '$TARGET_DIR'"

# 2. Create 4 randomly named files
log_step "Creating 4 randomly named files..."
for _ in {1..4}; do
	# Generate a random 8-character alphanumeric string
	RAND_STR=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
	FILE_PATH="$TARGET_DIR/file_${RAND_STR}.txt"

	touch "$FILE_PATH"
	CREATED_FILES+=("$FILE_PATH")
done

# 3. Create 4 randomly named directories
log_step "Creating 4 randomly named directories..."
for _ in {1..4}; do
	RAND_STR=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
	DIR_PATH="$TARGET_DIR/dir_${RAND_STR}"

	mkdir "$DIR_PATH"
	CREATED_DIRS+=("$DIR_PATH")
done

# 4. Summarize the files & dirs created
log_step "Summary of created items:"
echo "-----------------------------------"
echo "Files Created:"
for file in "${CREATED_FILES[@]}"; do
	echo "  - $file"
done

echo "Directories Created:"
for dir in "${CREATED_DIRS[@]}"; do
	echo "  - $dir"
done
echo "-----------------------------------"

# Sleep for a brief second just so you can see a slight difference in timestamps (optional)
sleep 1

# 5. Clean up the files and directories
log_step "Cleaning up created files and directories..."

for file in "${CREATED_FILES[@]}"; do
	rm "$file"
done

for dir in "${CREATED_DIRS[@]}"; do
	rmdir "$dir" # Using rmdir is safer since we know they are empty
done

log_step "Cleanup complete. Script finished successfully."
