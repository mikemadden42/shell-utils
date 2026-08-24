#!/usr/bin/env bash
set -euo pipefail

# Mirrors the Anthropic Claude Code native binaries. The official installer
# resolves a version, reads manifest.json, and downloads the single binary for
# the current platform. This downloads the binary for every platform the
# manifest advertises into claude-<version>/ and verifies each against the
# SHA256 checksum and byte size the manifest records.
#
# The platform list is not hardcoded: whatever manifest.json lists is what gets
# mirrored, so newly added architectures are picked up automatically.
#
# Usage: download-claude-code.bash [VERSION]   (VERSION defaults to stable)

VERSION_INPUT="${1:-${CLAUDE_CODE_RELEASE:-stable}}"
BASE_URL="${CLAUDE_CODE_RELEASES_BASE_URL:-https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases}"

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

is_version() {
	[[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]
}

# Accept a literal version, or a channel name that resolves to one.
version="${VERSION_INPUT#v}"
if ! is_version "$version"; then
	if [[ ! $version =~ ^[a-z][a-z0-9-]*$ ]]; then
		echo "Error: invalid version '${VERSION_INPUT}'. Expected x.y.z or a channel name." >&2
		exit 1
	fi
	echo "Resolving channel '${version}'..."
	version="$(curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/${version}")"
	version="${version//[$'\r\n\t ']/}"
	if ! is_version "$version"; then
		echo "Error: channel '${VERSION_INPUT}' resolved to invalid version '${version}'." >&2
		exit 1
	fi
fi

echo "Fetching manifest (${version})..."
manifest="$(curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/${version}/manifest.json")"

VERSION="$(jq -r '.version // empty' <<<"$manifest")"
if [[ $VERSION != "$version" ]]; then
	echo "Error: manifest version '${VERSION}' does not match requested ${version}." >&2
	exit 1
fi

mapfile -t platforms < <(jq -r '.platforms | keys_unsorted[]' <<<"$manifest")
if ((${#platforms[@]} == 0)); then
	echo "Error: manifest lists no platforms." >&2
	exit 1
fi

echo "Downloading version ${VERSION} (${#platforms[@]} platforms)..."

outdir="claude-${VERSION}"
mkdir -p "$outdir"
cd "$outdir"

sums_file="claude-${VERSION}-sha256sums.txt"
: >"$sums_file"

files=()

for platform in "${platforms[@]}"; do
	binary="$(jq -r --arg p "$platform" '.platforms[$p].binary // empty' <<<"$manifest")"
	digest="$(jq -r --arg p "$platform" '.platforms[$p].checksum // empty' <<<"$manifest")"
	size="$(jq -r --arg p "$platform" '.platforms[$p].size // empty' <<<"$manifest")"
	if [[ -z $binary || ! $digest =~ ^[0-9a-f]{64}$ || ! $size =~ ^[0-9]+$ ]]; then
		echo "Error: incomplete manifest entry for ${platform}." >&2
		exit 1
	fi

	# Local names keep the platform in the filename; the manifest's binary name
	# only contributes its extension (claude vs claude.exe).
	ext=""
	[[ $binary == *.* ]] && ext=".${binary##*.}"
	file="claude-${VERSION}-${platform}${ext}"
	url="${BASE_URL}/${VERSION}/${platform}/${binary}"

	printf '[%s] %s (%s MiB)\n' "$platform" "$file" "$((size / 1048576))"

	# Skip only when the existing file already matches the advertised checksum.
	if [[ -f $file && "$(sha256_of "$file")" == "$digest" ]]; then
		echo "  already complete, skipping"
		printf '%s  %s\n' "$digest" "$file" >>"$sums_file"
		files+=("$file")
		continue
	fi

	curl -fL --progress-bar -C - -R \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
		--retry 3 --retry-delay 2 --connect-timeout 15 \
		"$url" -o "$file"

	actual_size="$(wc -c <"$file" | tr -dc '0-9')"
	if [[ $actual_size != "$size" ]]; then
		echo "Error: size mismatch for ${file}: expected ${size}, got ${actual_size}." >&2
		exit 1
	fi
	actual="$(sha256_of "$file")"
	if [[ $actual != "$digest" ]]; then
		echo "Error: checksum mismatch for ${file}" >&2
		echo "  expected ${digest}" >&2
		echo "  actual   ${actual}" >&2
		echo "  delete the file and re-run to download it fresh." >&2
		exit 1
	fi
	echo "  verified ${digest}"
	printf '%s  %s\n' "$digest" "$file" >>"$sums_file"
	files+=("$file")
done

chmod +x "${files[@]}"

echo
echo "SHA256 sums written to ${outdir}/${sums_file}"
cat "$sums_file"
