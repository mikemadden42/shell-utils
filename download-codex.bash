#!/usr/bin/env bash
set -euo pipefail

# Mirrors the OpenAI Codex CLI standalone package archives. The official
# install.sh resolves a release, downloads one codex-package-<target>.tar.gz
# for the current platform, and unpacks it into ~/.codex. This downloads the
# package archive for every platform into codex-<version>/ and verifies each
# against the SHA256 digest the release metadata advertises.
#
# Usage: download-codex.bash [VERSION]   (VERSION defaults to latest)

VERSION_INPUT="${1:-${CODEX_RELEASE:-latest}}"
BASE_URL="${CODEX_RELEASES_BASE_URL:-https://releases.openai.com/codex}"

# Rust target triples to mirror, in download order. Each maps to the asset
# codex-package-<target>.tar.gz (a self-contained package: codex plus the
# codex-code-mode-host, rg, and — on Linux — bwrap helpers).
TARGETS=(
	aarch64-apple-darwin
	x86_64-apple-darwin
	aarch64-unknown-linux-musl
	x86_64-unknown-linux-musl
	aarch64-pc-windows-msvc
	x86_64-pc-windows-msvc
)

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

# Accept latest, x.y.z, and pre-releases, with or without a rust-v / v prefix.
version="${VERSION_INPUT#rust-v}"
version="${version#v}"
if [[ $version != latest &&
	! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-alpha(\.[0-9]+){0,2}|-beta(\.[0-9]+)?)?$ ]]; then
	echo "Error: invalid version '${VERSION_INPUT}'. Expected latest or x.y.z[-alpha|-beta]." >&2
	exit 1
fi

if [[ $version == latest ]]; then
	metadata_url="$BASE_URL/channels/latest"
else
	metadata_url="$BASE_URL/releases/$version/release.json"
fi

echo "Fetching release metadata (${version})..."
metadata="$(curl -fsSL --connect-timeout 10 --max-time 30 "$metadata_url")"

# tag_name looks like rust-v0.147.0; the release version is the part after it.
tag="$(jq -r '.tag_name // empty' <<<"$metadata")"
VERSION="${tag#rust-v}"
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
	echo "Error: could not resolve version from metadata (tag '${tag}')." >&2
	exit 1
fi
if [[ $version != latest && $VERSION != "$version" ]]; then
	echo "Error: metadata version ${VERSION} does not match requested ${version}." >&2
	exit 1
fi

outdir="codex-${VERSION}"
mkdir -p "$outdir"
cd "$outdir"

sums_file="codex-${VERSION}-SHA256SUMS.txt"
: >"$sums_file"

for target in "${TARGETS[@]}"; do
	asset="codex-package-${target}.tar.gz"
	entry="$(jq -c --arg n "$asset" '.assets[] | select(.name == $n)' <<<"$metadata")"
	if [[ -z $entry ]]; then
		echo "[${target}] ${asset} not in release, skipping"
		continue
	fi
	url="$(jq -r '.browser_download_url' <<<"$entry")"
	digest="$(jq -r '.digest' <<<"$entry")"
	digest="${digest#sha256:}"
	if [[ ! $digest =~ ^[0-9a-f]{64}$ ]]; then
		echo "Error: bad digest for ${asset}." >&2
		exit 1
	fi

	echo "[${target}] ${asset}"

	# Skip only when the existing file already matches the advertised digest.
	if [[ -f $asset && "$(sha256_of "$asset")" == "$digest" ]]; then
		echo "  already complete, skipping"
		printf '%s  %s\n' "$digest" "$asset" >>"$sums_file"
		continue
	fi

	curl -fL --progress-bar -C - -R \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
		--retry 3 --retry-delay 2 --connect-timeout 15 \
		"$url" -o "$asset"

	actual="$(sha256_of "$asset")"
	if [[ $actual != "$digest" ]]; then
		echo "Error: checksum mismatch for ${asset}" >&2
		echo "  expected ${digest}" >&2
		echo "  actual   ${actual}" >&2
		echo "  delete the file and re-run to download it fresh." >&2
		exit 1
	fi
	echo "  verified ${digest}"
	printf '%s  %s\n' "$digest" "$asset" >>"$sums_file"
done

echo
echo "SHA256 sums written to ${outdir}/${sums_file}"
cat "$sums_file"
