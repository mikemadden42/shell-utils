#!/usr/bin/env bash
set -euo pipefail

# Mirrors the Kimi Code CLI ("kimi") native binaries. The official install.sh
# resolves a version, reads a per-version manifest.json, downloads the single
# binary for the current platform, and installs it as kimi. This walks the
# manifest and downloads every platform's binary into kimi-code-<version>/,
# verifying each against the SHA256 the manifest advertises.
#
# Usage: download-kimi.bash [VERSION]   (VERSION defaults to latest)

BASE_URL="${KIMI_DOWNLOAD_BASE:-https://code.kimi.com/kimi-code}"
BINARY_BASE="${BASE_URL}/binaries"
VERSION_INPUT="${1:-${KIMI_VERSION:-latest}}"

for required in curl jq; do
	command -v "$required" >/dev/null ||
		{
			echo "Error: required command not found: ${required}" >&2
			exit 1
		}
done

if command -v sha256sum >/dev/null; then
	sha256=(sha256sum)
else
	sha256=(shasum -a 256)
fi

sha256_of() {
	local out
	out="$("${sha256[@]}" "$1")" || return 1
	printf '%s' "${out%% *}"
}

# Resolve the version: latest (plain-text endpoint) or a pinned x.y.z.
version="${VERSION_INPUT#v}"
if [[ $version == latest ]]; then
	echo "Resolving latest version from ${BASE_URL}/latest..."
	version="$(curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/latest" | tr -d '[:space:]')"
	[[ -n $version ]] || {
		echo "Error: could not resolve latest version." >&2
		exit 1
	}
fi
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
	echo "Error: invalid version '${VERSION_INPUT}'." >&2
	exit 1
fi

echo "Fetching manifest for ${version}..."
manifest="$(curl -fsSL --connect-timeout 10 --max-time 30 "${BINARY_BASE}/${version}/manifest.json")"

# The manifest carries the authoritative version; trust it for naming.
VERSION="$(jq -r '.version // empty' <<<"$manifest")"
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
	echo "Error: manifest has no usable version." >&2
	exit 1
fi

outdir="kimi-code-${VERSION}"
mkdir -p "$outdir"
cd "$outdir"

sums_file="kimi-code-${VERSION}-sha256sums.txt"
: >"$sums_file"

# Mirror whatever platforms the manifest publishes (keys are sorted: darwin,
# linux, then win32), so newly added targets are picked up automatically.
while IFS= read -r platform; do
	[[ -n $platform ]] || continue
	entry="$(jq -c --arg p "$platform" '.platforms[$p]' <<<"$manifest")"
	filename="$(jq -r '.filename // empty' <<<"$entry")"
	checksum="$(jq -r '.checksum // empty' <<<"$entry")"
	if [[ -z $filename ]]; then
		echo "[${platform}] no filename in manifest, skipping"
		continue
	fi
	if [[ ! $checksum =~ ^[0-9a-f]{64}$ ]]; then
		echo "Error: bad checksum for ${platform}." >&2
		exit 1
	fi

	echo "[${platform}] ${filename}"

	# Skip only when the existing file already matches the advertised digest.
	if [[ -f $filename && "$(sha256_of "$filename")" == "$checksum" ]]; then
		echo "  already complete, skipping"
		printf '%s  %s\n' "$checksum" "$filename" >>"$sums_file"
		continue
	fi

	curl -fL --progress-bar -C - -R \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
		--retry 3 --retry-delay 2 --connect-timeout 15 \
		"${BINARY_BASE}/${VERSION}/${filename}" -o "$filename"

	actual="$(sha256_of "$filename")"
	if [[ $actual != "$checksum" ]]; then
		echo "Error: checksum mismatch for ${filename}" >&2
		echo "  expected ${checksum}" >&2
		echo "  actual   ${actual}" >&2
		echo "  delete the file and re-run to download it fresh." >&2
		exit 1
	fi
	echo "  verified ${checksum}"
	printf '%s  %s\n' "$checksum" "$filename" >>"$sums_file"

	[[ $filename == *.exe ]] || chmod +x "$filename"
done < <(jq -r '.platforms | keys[]' <<<"$manifest")

echo
echo "SHA256 sums written to ${outdir}/${sums_file}"
cat "$sums_file"
