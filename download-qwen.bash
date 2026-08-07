#!/usr/bin/env bash
set -euo pipefail

# Mirrors the Qwen Code CLI standalone archives. The official
# install-qwen-standalone.sh resolves a version, downloads one
# qwen-code-<target>.<ext> archive for the current platform, verifies it
# against SHA256SUMS, and unpacks it. This downloads SHA256SUMS and every
# archive it lists into qwen-code-<version>/, verifying each checksum.
#
# SHA256SUMS is itself the manifest, so this mirrors exactly what the release
# publishes (currently macOS/Linux .tar.gz plus a Windows x64 .zip) and needs
# no JSON parser.
#
# Usage: download-qwen.bash [VERSION]   (VERSION defaults to latest)

RELEASE_BASE="${QWEN_RELEASE_BASE:-https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/releases/qwen-code}"
VERSION_INPUT="${1:-${QWEN_INSTALL_VERSION:-latest}}"

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

# Resolve the version path (the release directory name, e.g. v0.21.7).
if [[ $VERSION_INPUT == latest ]]; then
	echo "Resolving latest version from ${RELEASE_BASE}/latest/VERSION..."
	version_path="$(curl -fsSL --connect-timeout 10 --max-time 30 "${RELEASE_BASE}/latest/VERSION" | tr -d '[:space:]')"
	[[ -n $version_path ]] || {
		echo "Error: could not resolve latest version." >&2
		exit 1
	}
else
	ver="${VERSION_INPUT#v}"
	if [[ ! $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
		echo "Error: invalid version '${VERSION_INPUT}'." >&2
		exit 1
	fi
	version_path="v${ver}"
fi
if [[ ! $version_path =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
	echo "Error: unexpected version path '${version_path}'." >&2
	exit 1
fi

VERSION="${version_path#v}"
base="${RELEASE_BASE}/${version_path}"

outdir="qwen-code-${VERSION}"
mkdir -p "$outdir"
cd "$outdir"

echo "Fetching SHA256SUMS for ${version_path}..."
curl -fsSL --connect-timeout 10 --max-time 30 "${base}/SHA256SUMS" -o SHA256SUMS
[[ -s SHA256SUMS ]] || {
	echo "Error: SHA256SUMS is empty or missing." >&2
	exit 1
}

# SHA256SUMS drives the mirror: one "<sha256>  [*]<name>" line per archive.
while read -r hash name <&3; do
	[[ -n $hash ]] || continue
	name="${name#\*}"    # binary-mode marker
	name="${name%$'\r'}" # tolerate CRLF
	if [[ ! $hash =~ ^[0-9a-f]{64}$ ]]; then
		echo "Error: malformed SHA256SUMS line for '${name}'." >&2
		exit 1
	fi

	echo "[${name}]"

	# Skip only when the existing file already matches the advertised digest.
	if [[ -f $name && "$(sha256_of "$name")" == "$hash" ]]; then
		echo "  already complete, skipping"
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
done 3<SHA256SUMS

echo
echo "SHA256SUMS written to ${outdir}/SHA256SUMS"
cat SHA256SUMS
