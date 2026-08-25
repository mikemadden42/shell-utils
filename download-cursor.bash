#!/usr/bin/env bash
set -euo pipefail

# Mirrors the Cursor Agent CLI ("cursor-agent") packages. The official
# installer at cursor.com/install detects the platform and downloads one
# agent-cli-package archive from downloads.cursor.com. This downloads the
# archive for every platform into cursor-agent-<version>/.
#
# Unlike the other mirrors here, Cursor publishes no checksums, manifest, or
# signatures for these archives -- the official installer pipes curl straight
# into tar. There is nothing upstream to verify against, so this records its
# own SHA256 sums and tests that each archive decompresses. Those sums attest
# to what was downloaded, not to what Cursor intended to publish.
#
# There is no version index either, so latest is resolved by reading the
# version the install script pins.
#
# Usage: download-cursor.bash [VERSION]   (VERSION defaults to latest)

INSTALL_URL="${CURSOR_INSTALL_URL:-https://cursor.com/install}"
BASE_URL="${CURSOR_DOWNLOAD_BASE:-https://downloads.cursor.com/lab}"
VERSION_INPUT="${1:-${CURSOR_VERSION:-latest}}"

# Platforms to mirror. There is no index endpoint to enumerate. The install
# script only ever builds linux/darwin x {x64,arm64} and rejects every other
# uname; the Windows archives are published alongside them (as .zip) even
# though no official installer requests them.
PLATFORMS=(
	darwin/arm64
	darwin/x64
	linux/arm64
	linux/x64
	windows/arm64
	windows/x64
)

command -v curl >/dev/null ||
	{
		echo "Error: curl is required." >&2
		exit 1
	}

if command -v sha256sum >/dev/null; then
	sha256=(sha256sum)
elif command -v shasum >/dev/null; then
	sha256=(shasum -a 256)
else
	echo "Error: sha256sum or shasum is required." >&2
	exit 1
fi

sha256_of() {
	local out
	out="$("${sha256[@]}" "$1")" || return 1
	printf '%s' "${out%% *}"
}

remote_size_of() {
	curl -fsSL -I --connect-timeout 10 --max-time 30 "$1" 2>/dev/null |
		grep -i '^content-length:' | tail -1 | tr -dc '0-9'
}

# With no upstream digest, decompressing is the only integrity signal there
# is: it catches truncation and corruption, though not substitution.
archive_ok() {
	case "$1" in
	*.tar.gz)
		gzip -t "$1" 2>/dev/null
		;;
	*.zip)
		# Treat a missing unzip as "cannot check" rather than a failure.
		command -v unzip >/dev/null || return 0
		unzip -tqq "$1" >/dev/null 2>&1
		;;
	*) return 0 ;;
	esac
}

# Resolve the version. The install script pins one, and is the only place it
# is published; every occurrence in it must agree.
version="$VERSION_INPUT"
if [[ $version == latest ]]; then
	echo "Resolving latest version from ${INSTALL_URL}..."
	install_script="$(curl -fsSL --connect-timeout 10 --max-time 30 "$INSTALL_URL")"
	mapfile -t found < <(grep -oE '20[0-9]{2}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{6,40}' <<<"$install_script" | sort -u)
	if ((${#found[@]} != 1)); then
		echo "Error: expected one version in the install script, found ${#found[@]}." >&2
		exit 1
	fi
	version="${found[0]}"
fi
if [[ ! $version =~ ^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{6,40}$ ]]; then
	echo "Error: invalid version '${VERSION_INPUT}'." >&2
	exit 1
fi
VERSION="$version"

echo "Downloading version ${VERSION} (${#PLATFORMS[@]} platforms)..."

outdir="cursor-agent-${VERSION}"
mkdir -p "$outdir"
cd "$outdir"

sums_file="cursor-agent-${VERSION}-sha256sums.txt"
: >"$sums_file"

for platform in "${PLATFORMS[@]}"; do
	os="${platform%%/*}"
	arch="${platform##*/}"
	# Windows packages ship as .zip, the rest as .tar.gz.
	ext=".tar.gz"
	[[ $os == windows ]] && ext=".zip"
	url="${BASE_URL}/${VERSION}/${os}/${arch}/agent-cli-package${ext}"
	# Every platform ships the same asset basename, so the local name has to
	# carry the platform itself.
	file="cursor-agent-${VERSION}-${os}-${arch}${ext}"

	echo "[${os}/${arch}] ${file}"

	# No digest to compare against, so fall back to the advertised size, and
	# require the archive to still be readable before trusting it.
	if [[ -f $file ]]; then
		remote_size="$(remote_size_of "$url")"
		local_size="$(wc -c <"$file" | tr -dc '0-9')"
		if [[ -n $remote_size && $local_size == "$remote_size" ]] && archive_ok "$file"; then
			echo "  already complete, skipping"
			printf '%s  %s\n' "$(sha256_of "$file")" "$file" >>"$sums_file"
			continue
		fi
	fi

	curl -fL --progress-bar -C - -R \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
		--retry 3 --retry-delay 2 --connect-timeout 15 \
		"$url" -o "$file"

	if ! archive_ok "$file"; then
		echo "Error: ${file} did not decompress cleanly; the download may be corrupt." >&2
		echo "  delete the file and re-run to download it fresh." >&2
		exit 1
	fi

	digest="$(sha256_of "$file")"
	echo "  ok ${digest}"
	printf '%s  %s\n' "$digest" "$file" >>"$sums_file"
done

echo
echo "SHA256 sums written to ${outdir}/${sums_file}"
echo "Note: these are computed locally; Cursor publishes no upstream digests."
cat "$sums_file"
