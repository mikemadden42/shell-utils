#!/usr/bin/env bash
set -euo pipefail

# Mirrors the muse ("Muse Code") platform binaries. The launcher script served
# at api.meta.ai/muse-launcher.sh is only a bootstrapper; the real binaries are
# resolved through two JSON manifests and live on lookaside.facebook.com. This
# walks the same manifests and downloads every artifact, verifying each against
# the SHA256 the release manifest advertises.

CHANNEL="${MUSE_CHANNEL:-muse-stable}"
CHANNEL_URL="${MUSE_CHANNEL_URL:-https://api.meta.ai/muse-code/channels/${CHANNEL}}"
USER_AGENT="muse-code/launcher-2"

# Manifest keys to mirror, in download order.
PLATFORMS=(aarch64_macos x86_macos aarch64_linux x86_linux universal_macos_pkg)

for required in curl jq; do
	command -v "$required" >/dev/null ||
		{ echo "Error: required command not found: ${required}" >&2; exit 1; }
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

fetch_json=(curl -fsSL
	--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3
	--user-agent "$USER_AGENT" --header 'Accept: application/json')

echo "Fetching channel manifest (${CHANNEL})..."
channel_json="$("${fetch_json[@]}" "$CHANNEL_URL")"
VERSION="$(jq -r '.version' <<<"$channel_json")"
manifest_url="$(jq -r '.manifest_url' <<<"$channel_json")"
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+-R[0-9]+(\.[0-9]+)?$ ]]; then
	echo "Error: unexpected version '${VERSION}'." >&2
	exit 1
fi
if [[ -z $manifest_url || $manifest_url != https://* ]]; then
	echo "Error: channel manifest has no usable manifest_url." >&2
	exit 1
fi

echo "Version ${VERSION}; fetching release manifest..."
release_json="$("${fetch_json[@]}" "$manifest_url")"
if [[ "$(jq -r '.checksum_algorithm' <<<"$release_json")" != sha256 ]]; then
	echo "Error: release manifest is not sha256-checksummed." >&2
	exit 1
fi

outdir="muse-${VERSION}"
mkdir -p "$outdir"
cd "$outdir"

sums_file="muse-${VERSION}-sha256sums.txt"
: >"$sums_file"

for platform in "${PLATFORMS[@]}"; do
	artifact="$(jq -c --arg p "$platform" '.artifacts[$p] // empty' <<<"$release_json")"
	if [[ -z $artifact ]]; then
		echo "[${platform}] not in manifest, skipping"
		continue
	fi
	url="$(jq -r '.url' <<<"$artifact")"
	checksum="$(jq -r '.checksum' <<<"$artifact")"
	size="$(jq -r '.size' <<<"$artifact")"
	if [[ ! $checksum =~ ^[0-9a-f]{64}$ || ! $size =~ ^[1-9][0-9]*$ ]]; then
		echo "Error: bad checksum/size for ${platform}." >&2
		exit 1
	fi

	file="muse-${VERSION}-${platform}"
	[[ $platform == *_pkg ]] && file="${file}.pkg"

	printf '[%s] %s (%s bytes)\n' "$platform" "$file" "$size"

	# Skip only when the existing file already matches the advertised digest.
	if [[ -f $file ]]; then
		local_size=$(wc -c <"$file" | tr -dc '0-9')
		if [[ $local_size == "$size" && "$(sha256_of "$file")" == "$checksum" ]]; then
			echo "  already complete, skipping"
			printf '%s  %s\n' "$checksum" "$file" >>"$sums_file"
			continue
		fi
	fi

	curl -fL --progress-bar -C - -R \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
		--retry 3 --retry-delay 2 --connect-timeout 15 \
		--user-agent "$USER_AGENT" \
		"$url" -o "$file"

	actual="$(sha256_of "$file")"
	if [[ $actual != "$checksum" ]]; then
		echo "Error: checksum mismatch for ${file}" >&2
		echo "  expected ${checksum}" >&2
		echo "  actual   ${actual}" >&2
		echo "  delete the file and re-run to download it fresh." >&2
		exit 1
	fi
	echo "  verified ${checksum}"
	printf '%s  %s\n' "$checksum" "$file" >>"$sums_file"

	[[ $platform == *_pkg ]] || chmod +x "$file"
done

echo
echo "SHA256 sums written to ${outdir}/${sums_file}"
cat "$sums_file"
