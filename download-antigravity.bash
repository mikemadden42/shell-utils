#!/usr/bin/env bash
set -euo pipefail

# Mirrors the Antigravity CLI ("agy") native builds. The official install.sh
# reads a per-platform manifest (version, url, sha512) from the Cloud Run
# auto-updater, downloads that platform's artifact, and installs it as agy.
# This walks every platform manifest and downloads each artifact into
# antigravity-<version>/, verifying it against the manifest's SHA512.
#
# The manifests only ever describe the current latest release; there is no
# versioned manifest endpoint, so this always mirrors latest.

BASE_URL="${ANTIGRAVITY_BASE_URL:-https://antigravity-cli-auto-updater-974169037036.us-central1.run.app}"

# Platform manifests to mirror. Antigravity ships glibc-only Linux builds
# (no musl) and does not publish 32-bit targets.
PLATFORMS=(
	darwin_amd64
	darwin_arm64
	linux_amd64
	linux_arm64
	windows_amd64
	windows_arm64
)

for required in curl jq; do
	command -v "$required" >/dev/null ||
		{
			echo "Error: required command not found: ${required}" >&2
			exit 1
		}
done

if command -v sha512sum >/dev/null; then
	sha512=(sha512sum)
	sha_style=coreutils
elif command -v shasum >/dev/null; then
	sha512=(shasum -a 512)
	sha_style=coreutils
elif command -v openssl >/dev/null; then
	sha512=(openssl dgst -sha512)
	sha_style=openssl
else
	echo "Error: sha512sum, shasum, or openssl is required." >&2
	exit 1
fi

sha512_of() {
	local out
	out="$("${sha512[@]}" "$1")" || return 1
	if [[ $sha_style == openssl ]]; then
		# "SHA2-512(file)= <hex>" -> "<hex>"
		out="${out##*=}"
		printf '%s' "${out# }"
	else
		printf '%s' "${out%% *}"
	fi
}

# Resolve every manifest first so the output directory can be named for the
# version before any large download starts.
VERSION=""
plats=() urls=() digests=() files=()
echo "Fetching manifests from ${BASE_URL}..."
for platform in "${PLATFORMS[@]}"; do
	manifest_url="$BASE_URL/manifests/${platform}.json"
	if ! manifest="$(curl -fsSL --connect-timeout 10 --max-time 30 "$manifest_url")"; then
		echo "  [${platform}] manifest unavailable, skipping"
		continue
	fi
	ver="$(jq -r '.version // empty' <<<"$manifest")"
	url="$(jq -r '.url // empty' <<<"$manifest")"
	digest="$(jq -r '.sha512 // empty' <<<"$manifest")"
	if [[ -z $url || -z $digest ]]; then
		echo "  [${platform}] malformed manifest, skipping"
		continue
	fi
	if [[ ! $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
		echo "Error: bad version '${ver}' for ${platform}." >&2
		exit 1
	fi
	if [[ ! $digest =~ ^[0-9a-f]{128}$ ]]; then
		echo "Error: bad sha512 for ${platform}." >&2
		exit 1
	fi
	if [[ -z $VERSION ]]; then
		VERSION="$ver"
	elif [[ $ver != "$VERSION" ]]; then
		echo "  [${platform}] version ${ver} differs from ${VERSION}, skipping"
		continue
	fi

	case "$url" in
	*.tar.gz*) ext=".tar.gz" ;;
	*.exe*) ext=".exe" ;;
	*) ext="" ;;
	esac

	plats+=("$platform")
	urls+=("$url")
	digests+=("$digest")
	files+=("antigravity-${VERSION}-${platform}${ext}")
done

if [[ -z $VERSION ]]; then
	echo "Error: no usable manifests found." >&2
	exit 1
fi

echo "Version ${VERSION} (${#files[@]} artifacts)"

outdir="antigravity-${VERSION}"
mkdir -p "$outdir"
cd "$outdir"

sums_file="antigravity-${VERSION}-SHA512SUMS.txt"
: >"$sums_file"

for i in "${!files[@]}"; do
	file="${files[i]}"
	url="${urls[i]}"
	digest="${digests[i]}"
	echo "[${plats[i]}] ${file}"

	# Skip only when the existing file already matches the advertised digest.
	if [[ -f $file && "$(sha512_of "$file")" == "$digest" ]]; then
		echo "  already complete, skipping"
		printf '%s  %s\n' "$digest" "$file" >>"$sums_file"
		continue
	fi

	curl -fL --progress-bar -C - -R \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
		--retry 3 --retry-delay 2 --connect-timeout 15 \
		"$url" -o "$file"

	actual="$(sha512_of "$file")"
	if [[ $actual != "$digest" ]]; then
		echo "Error: checksum mismatch for ${file}" >&2
		echo "  expected ${digest}" >&2
		echo "  actual   ${actual}" >&2
		echo "  delete the file and re-run to download it fresh." >&2
		exit 1
	fi
	echo "  verified sha512"
	printf '%s  %s\n' "$digest" "$file" >>"$sums_file"
done

echo
echo "SHA512 sums written to ${outdir}/${sums_file}"
cat "$sums_file"
