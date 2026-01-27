#!/usr/bin/env bash
set -euo pipefail

out_dir="${1:-$HOME}"
dpkg_out="$out_dir/dpkg_history.log"
apt_out="$out_dir/apt_history.log"

cat_log() {
	local f="$1"
	case "$f" in
	*.gz) gzip -dc -- "$f" ;;
	*.xz) xz -dc -- "$f" ;;
	*.zst) zstd -dc -- "$f" ;;
	*) cat -- "$f" ;;
	esac
}

# Print matching files oldest->newest by mtime.
# (Uses find so we don't rely on ls parsing.)
sorted_logs() {
	local dir="$1" pattern="$2"
	find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' |
		sort -n |
		awk '{print $2}'
}

# --- DPKG history ---
mapfile -t dpkg_files < <(sorted_logs /var/log 'dpkg.log*')
{
	for f in "${dpkg_files[@]}"; do
		cat_log "$f"
	done
} 2>/dev/null |
	awk '$3 ~ /^(install|upgrade|remove|purge)$/ {print}' \
		>"$dpkg_out"

# --- APT history ---
mapfile -t apt_files < <(sorted_logs /var/log/apt 'history.log*')
{
	for f in "${apt_files[@]}"; do
		cat_log "$f"
	done
} 2>/dev/null \
	>"$apt_out"

printf 'Wrote:\n  %s\n  %s\n' "$dpkg_out" "$apt_out"
