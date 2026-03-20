#!/bin/bash

# 1. Use robust user detection (safe for Cron)
BACKUP_USER=$(id -un)
NOW=$(date +%Y-%m-%d-%H-%M)
# 2. Define paths clearly
TARGET_DIR="/tmp"
ARCHIVE_NAME="${BACKUP_USER}-${NOW}.tar.gz"

# 3. Change directory safely
cd "/home" || {
	echo "Failed to cd to /home"
	exit 1
}

# 4. Run Tar
# - Using gzip (-z) for speed balance. Switch to --zstd if installed on Alma 9.
# - Removed the empty --exclude
# - Added verbose (-v) removal for cron (optional, keeps logs cleaner)
tar --exclude "${BACKUP_USER}/.cargo" \
	--exclude "${BACKUP_USER}/.rustup" \
	-czvf "${TARGET_DIR}/${ARCHIVE_NAME}" \
	"${BACKUP_USER}"

# 5. Capture exit code to warn on 'changed files' vs 'fatal error'
TAR_STATUS=$?
if [ $TAR_STATUS -ne 0 ] && [ $TAR_STATUS -ne 1 ]; then
	echo "Critical tar failure. Status: $TAR_STATUS"
	exit $TAR_STATUS
fi

cd "${TARGET_DIR}" || exit
sha256sum "${ARCHIVE_NAME}" >"${ARCHIVE_NAME}.sha256"
