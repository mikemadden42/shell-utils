#!/bin/bash
set -uo pipefail

# Archives the invoking user's home directory.
#
# The archive must not land in /tmp on this host: /tmp is a 16G tmpfs, so a
# ~20G backup fills RAM and dies with EDQUOT part-written. BACKUP_DIR must be
# a real disk, and it must not be inside the directory being archived, or the
# archive feeds itself.

BACKUP_USER=$(id -un)
HOSTNAME_SHORT=$(hostname -s)
NOW=$(date +%Y-%m-%d-%H-%M)
TARGET_DIR="${BACKUP_DIR:-/var/tmp}"

# Caches and toolchain downloads are big and all re-fetchable. ~/opt and
# ~/Downloads are deliberately kept; add them here if you would rather not
# carry them.
EXCLUDES=(
	"${BACKUP_USER}/.cache"
	"${BACKUP_USER}/.cargo"
	"${BACKUP_USER}/.nv"
	"${BACKUP_USER}/.ollama"
	"${BACKUP_USER}/.rustup"
)

# zstd -T0 uses every core; gzip is single-threaded and was the reason a run
# took 17 minutes. pigz is the fallback, plain gzip the last resort.
if command -v zstd >/dev/null; then
	compressor=(zstd -T0 -3)
	ext="tar.zst"
elif command -v pigz >/dev/null; then
	compressor=(pigz)
	ext="tar.gz"
else
	compressor=(gzip)
	ext="tar.gz"
fi

ARCHIVE_NAME="${BACKUP_USER}-${HOSTNAME_SHORT}-${NOW}.${ext}"
ARCHIVE_PATH="${TARGET_DIR}/${ARCHIVE_NAME}"

if [ ! -d "$TARGET_DIR" ] || [ ! -w "$TARGET_DIR" ]; then
	echo "Backup directory is missing or not writable: ${TARGET_DIR}"
	exit 1
fi

# Resolve both sides before comparing: a symlinked target would otherwise slip
# past this and end up inside the archive.
real_target=$(readlink -f "$TARGET_DIR")
real_home=$(readlink -f "/home/${BACKUP_USER}")
case "$real_target/" in
"$real_home"/*)
	echo "Backup directory ${real_target} is inside ${real_home}; pick one outside it."
	exit 1
	;;
esac

cd "/home" || {
	echo "Failed to cd to /home"
	exit 1
}

# Fail in seconds rather than part-way through a long run: compare the size of
# what will actually be archived against what the target can take.
echo "Measuring ${BACKUP_USER}..."
# du is run from /home with the same relative paths tar sees, so the exclude
# patterns transfer unchanged.
du_excludes=()
for exclude in "${EXCLUDES[@]}"; do
	du_excludes+=(--exclude="$exclude")
done
need_kb=$(du -sk "${du_excludes[@]}" "$BACKUP_USER" 2>/dev/null | cut -f1)
free_kb=$(df -Pk "$real_target" | awk 'NR == 2 { print $4 }')
printf 'To archive: %s GiB uncompressed; free on %s: %s GiB\n' \
	"$((need_kb / 1048576))" "$real_target" "$((free_kb / 1048576))"
if [ "$need_kb" -gt "$free_kb" ]; then
	echo "Not enough room for the uncompressed size; refusing to start."
	exit 1
fi

# A partial archive is worse than none: it looks like a backup and wastes the
# space that made the run fail.
cleanup() {
	status=$?
	if [ "$status" -ne 0 ] && [ "$status" -ne 1 ] && [ -f "$ARCHIVE_PATH" ]; then
		echo "Removing partial archive ${ARCHIVE_PATH}"
		rm -f "$ARCHIVE_PATH"
	fi
}
trap cleanup EXIT

tar_excludes=()
for exclude in "${EXCLUDES[@]}"; do
	tar_excludes+=(--exclude="$exclude")
done

echo "Writing ${ARCHIVE_PATH}..."
tar "${tar_excludes[@]}" \
	--use-compress-program="${compressor[*]}" \
	-cf "$ARCHIVE_PATH" \
	"$BACKUP_USER"
TAR_STATUS=$?

# 1 is "files changed while reading", normal on a live home directory.
if [ "$TAR_STATUS" -ne 0 ] && [ "$TAR_STATUS" -ne 1 ]; then
	echo "Critical tar failure. Status: ${TAR_STATUS}"
	exit "$TAR_STATUS"
fi
if [ "$TAR_STATUS" -eq 1 ]; then
	echo "Note: some files changed while being read."
fi

cd "$TARGET_DIR" || exit 1
sha256sum "$ARCHIVE_NAME" >"${ARCHIVE_NAME}.sha256"

printf 'Wrote %s (%s)\n' "$ARCHIVE_PATH" "$(du -h "$ARCHIVE_NAME" | cut -f1)"
cat "${ARCHIVE_NAME}.sha256"
