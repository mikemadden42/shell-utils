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
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
	echo "Error: Invalid version '${VERSION}'." >&2
	exit 1
fi

urls=()
files=()
for platform in "${PLATFORMS[@]}"; do
	suffix=""
	[[ $platform == win32-* ]] && suffix=".exe"
	urls+=("${BASE_URL}/${VERSION}/${platform}/claude${suffix}")
	files+=("claude-${VERSION}-${platform}${suffix}")
done

echo "Downloading version ${VERSION} (${#urls[@]} files)..."

mkdir -p "claude-${VERSION}"
cd "claude-${VERSION}"

for i in "${!urls[@]}"; do
	printf '[%d/%d] %s\n' "$((i + 1))" "${#urls[@]}" "${files[i]}"
	if [[ -f ${files[i]} ]]; then
		remote_size=$(curl -fsSL -I "${urls[i]}" | grep -i '^content-length:' | tail -1 | tr -dc '0-9' || true)
		local_size=$(wc -c <"${files[i]}" | tr -dc '0-9')
		if [[ -n $remote_size && $local_size == "$remote_size" ]]; then
			echo "already complete, skipping"
			continue
		fi
	fi
	curl -fL --progress-bar -C - -R "${urls[i]}" -o "${files[i]}"
done

chmod +x "${files[@]}"

"${sha256[@]}" "${files[@]}" >"claude-${VERSION}-sha256sums.txt"

echo "SHA256 sums written to claude-${VERSION}/claude-${VERSION}-sha256sums.txt"
cat "claude-${VERSION}-sha256sums.txt"
