#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

PLATFORMS=(darwin-arm64 darwin-x64 linux-arm64 linux-x64 win32-x64)

if command -v sha256sum >/dev/null; then
	sha256=(sha256sum)
else
	sha256=(shasum -a 256)
fi

VERSION="${1:-$(curl -fsSL "${BASE_URL}/stable")}"
if [[ -z $VERSION ]]; then
	echo "Error: Failed to fetch latest version." >&2
	exit 1
fi
echo "Downloading version ${VERSION}..."
for platform in "${PLATFORMS[@]}"; do
	suffix=""
	[[ $platform == win32-* ]] && suffix=".exe"
	echo "  ${BASE_URL}/${VERSION}/${platform}/claude${suffix}"
done

mkdir -p "claude-${VERSION}"
cd "claude-${VERSION}"

files=()
for platform in "${PLATFORMS[@]}"; do
	suffix=""
	[[ $platform == win32-* ]] && suffix=".exe"
	out="claude-${VERSION}-${platform}${suffix}"
	curl -fsSL "${BASE_URL}/${VERSION}/${platform}/claude${suffix}" -o "$out" || {
		echo "Error: Failed to download ${platform} binary." >&2
		exit 1
	}
	files+=("$out")
done

chmod +x "${files[@]}"

"${sha256[@]}" "${files[@]}" >"claude-${VERSION}-sha256sums.txt"

echo "SHA256 sums written to claude-${VERSION}/claude-${VERSION}-sha256sums.txt"
cat "claude-${VERSION}-sha256sums.txt"
