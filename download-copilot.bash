#!/usr/bin/env bash
set -euo pipefail

# Mirrors the GitHub Copilot CLI standalone builds. The release publishes each
# platform as a copilot-<platform>.<ext> archive plus a Windows .msi, and a
# SHA256SUMS.txt covering them. This downloads every copilot-* asset into
# copilot-cli-<version>/ and verifies each against that file.
#
# The release also ships github-copilot-<version>-*.tgz npm packages, which
# repackage the same builds for a different channel; those are listed in
# SHA256SUMS.txt but deliberately not mirrored here, the way download-codex.bash
# mirrors only the package archives.
#
# Usage: download-copilot.bash [VERSION]   (VERSION defaults to latest)

REPO_URL="${COPILOT_REPO_URL:-https://github.com/github/copilot-cli}"
VERSION_INPUT="${1:-${COPILOT_VERSION:-latest}}"

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

# Resolve the release tag. /releases/latest redirects to /releases/tag/<tag>,
# which avoids the GitHub API and its unauthenticated rate limit.
if [[ $VERSION_INPUT == latest ]]; then
	echo "Resolving latest release from ${REPO_URL}..."
	effective="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
		--connect-timeout 10 --max-time 30 "${REPO_URL}/releases/latest")"
	tag="${effective##*/tag/}"
	if [[ $tag == "$effective" || -z $tag ]]; then
		echo "Error: could not resolve the latest tag from '${effective}'." >&2
		exit 1
	fi
else
	tag="v${VERSION_INPUT#v}"
fi

VERSION="${tag#v}"
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
	echo "Error: invalid version '${VERSION_INPUT}' (tag '${tag}')." >&2
	exit 1
fi

base="${REPO_URL}/releases/download/${tag}"

outdir="copilot-cli-${VERSION}"
mkdir -p "$outdir"
cd "$outdir"

echo "Fetching SHA256SUMS.txt for ${tag}..."
curl -fsSL --connect-timeout 10 --max-time 30 "${base}/SHA256SUMS.txt" -o SHA256SUMS.txt
[[ -s SHA256SUMS.txt ]] || {
	echo "Error: SHA256SUMS.txt is empty or missing." >&2
	exit 1
}

sums_file="copilot-cli-${VERSION}-SHA256SUMS.txt"
: >"$sums_file"

# SHA256SUMS.txt drives the mirror: one "<sha256>  [*]<name>" line per asset.
mirrored=0
while read -r hash name <&3; do
	[[ -n $hash ]] || continue
	name="${name#\*}"    # binary-mode marker
	name="${name%$'\r'}" # tolerate CRLF
	if [[ ! $hash =~ ^[0-9a-f]{64}$ ]]; then
		echo "Error: malformed SHA256SUMS.txt line for '${name}'." >&2
		exit 1
	fi
	# Standalone builds only; github-copilot-*.tgz are the npm channel.
	[[ $name == copilot-* ]] || continue

	echo "[${name}]"

	# Skip only when the existing file already matches the advertised digest.
	if [[ -f $name && "$(sha256_of "$name")" == "$hash" ]]; then
		echo "  already complete, skipping"
		printf '%s  %s\n' "$hash" "$name" >>"$sums_file"
		mirrored=$((mirrored + 1))
		continue
	fi

	curl -fL --progress-bar -C - -R \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
		--retry 3 --retry-delay 2 --connect-timeout 15 \
		"${base}/${name}" -o "$name"

	actual="$(sha256_of "$name")"
	if [[ $actual != "$hash" ]]; then
		echo "Error: checksum mismatch for ${name}" >&2
		echo "  expected ${hash}" >&2
		echo "  actual   ${actual}" >&2
		echo "  delete the file and re-run to download it fresh." >&2
		exit 1
	fi
	echo "  verified ${hash}"
	printf '%s  %s\n' "$hash" "$name" >>"$sums_file"
	mirrored=$((mirrored + 1))
done 3<SHA256SUMS.txt

if ((mirrored == 0)); then
	echo "Error: SHA256SUMS.txt listed no copilot-* assets." >&2
	exit 1
fi

echo
echo "Mirrored ${mirrored} assets; SHA256 sums written to ${outdir}/${sums_file}"
cat "$sums_file"
