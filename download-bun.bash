#!/usr/bin/env bash
set -euo pipefail

# Download the latest stable Bun release from GitHub
# (https://github.com/oven-sh/bun/releases) into the current directory, and
# verify it against the size and SHA-256 digest GitHub publishes.
#
# By default it picks the build for this OS and CPU, the same variant as Bun's
# install script: musl on musl Linux, "baseline" on x64 CPUs without AVX2, and
# the native arm64 build when an x64 process is running under Rosetta 2 on
# Apple silicon. --all instead downloads the builds for the common platforms.
#
# Usage: download-bun.bash [--all]
#
# Environment:
#   GITHUB_TOKEN          optional; raises the API rate limit (60/hour without)
#   BUN_RELEASE_API_URL   override the release metadata URL (for mirrors/tests)

API_URL="${BUN_RELEASE_API_URL:-https://api.github.com/repos/oven-sh/bun/releases/latest}"
MIB=$((1024 * 1024))

# What --all downloads: glibc and musl Linux, macOS and Windows, on x64 and
# arm64. Not the baseline, profile, Android or FreeBSD builds.
ALL_TARGETS=(
	darwin-aarch64
	darwin-x64
	linux-aarch64
	linux-aarch64-musl
	linux-x64
	linux-x64-musl
	windows-aarch64
	windows-x64
)

usage() {
	cat <<'EOF'
Usage: download-bun.bash [--all]

Download the latest stable Bun release for this OS and CPU into the
current directory. Set GITHUB_TOKEN to raise the GitHub API rate limit.

  --all    download the macOS, Linux (glibc and musl) and Windows builds
           for x64 and arm64 instead
EOF
}

all=false
if (($# > 1)); then
	printf 'Error: unexpected argument '\''%s'\''.\n\n' "$2" >&2
	usage >&2
	exit 1
fi
case "${1-}" in
'') ;;
-h | --help)
	usage
	exit 0
	;;
--all) all=true ;;
*)
	printf 'Error: unexpected argument '\''%s'\''.\n\n' "$1" >&2
	usage >&2
	exit 1
	;;
esac

die() {
	echo "Error: $*" >&2
	exit 1
}

for required in curl jq; do
	command -v "$required" >/dev/null || die "required command not found: ${required}"
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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# --- choosing the build ------------------------------------------------------

sysctl_value() {
	sysctl -n "$1" 2>/dev/null || true
}

# Look at the machine we're on and print its release target, such as
# "linux-x64-musl-baseline". Only probes what matters for the result, and
# assumes AVX2 where it can't tell (as Bun's installer does).
detect_target() {
	local kernel machine os cpu target
	local musl=false avx2=true rosetta=false android=false
	kernel="$(uname -s)"
	machine="$(uname -m)"

	case "$kernel" in
	Darwin) os=darwin ;;
	Linux)
		os=linux
		# Bun ships Android as linux-<arch>-android.
		[[ "$(uname -o 2>/dev/null)" == Android ]] && android=true
		;;
	FreeBSD) os=freebsd ;;
	MINGW* | MSYS* | CYGWIN*) os=windows ;;
	*) die "unsupported operating system: ${kernel}" ;;
	esac

	case "$machine" in
	x86_64 | amd64) cpu=x64 ;;
	arm64 | aarch64) cpu=aarch64 ;;
	*) die "unsupported CPU architecture: ${machine}" ;;
	esac

	if [[ $os == linux ]] && ! $android; then
		# getconf only knows GNU_LIBC_VERSION when linked against glibc.
		getconf GNU_LIBC_VERSION >/dev/null 2>&1 || musl=true
		if [[ $cpu == x64 && -r /proc/cpuinfo ]]; then
			grep -qw avx2 /proc/cpuinfo || avx2=false
		fi
	elif [[ $os == darwin && $cpu == x64 ]]; then
		# An x64 process under Rosetta 2 can run the native arm64 build.
		if [[ "$(sysctl_value sysctl.proc_translated)" == 1 ]]; then
			rosetta=true
			cpu=aarch64
		fi
		if ! $rosetta && [[ ! "$(sysctl_value machdep.cpu.leaf7_features)" =~ (^|[[:space:]])AVX2($|[[:space:]]) ]]; then
			avx2=false
		fi
	fi

	target="${os}-${cpu}"
	if $android; then
		target+=-android
	elif $musl; then
		target+=-musl
	fi
	if [[ $cpu == x64 ]] && ! $avx2; then
		target+=-baseline
	fi
	printf '%s' "$target"
}

# --- downloading -------------------------------------------------------------

# HTTPS only, except plain HTTP to this machine (local mirrors and tests).
# Prints the curl protocol list to allow, for both the URL and its redirects.
allowed_protocols() {
	case "$1" in
	https://*) printf '=https' ;;
	http://localhost[:/]* | http://127.0.0.1[:/]* | 'http://[::1]'[:/]*) printf '=http,https' ;;
	*) return 1 ;;
	esac
}

# Fetch API JSON into stdout, explaining a rate-limit failure.
get_json() {
	local url="$1" headers body status
	local args=(-sSL --connect-timeout 10 --max-time 30
		-H 'Accept: application/vnd.github+json'
		-H 'X-GitHub-Api-Version: 2022-11-28')
	[[ -n ${GITHUB_TOKEN-} ]] && args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

	headers="${tmpdir}/headers"
	body="${tmpdir}/body"
	status="$(curl "${args[@]}" -D "$headers" -o "$body" -w '%{http_code}' "$url")" ||
		die "could not fetch ${url}"
	if [[ $status != 2?? ]]; then
		local hint=""
		if [[ $status == 403 || $status == 429 ]] &&
			grep -qi '^x-ratelimit-remaining: *0' "$headers"; then
			hint=" (GitHub API rate limit reached; set GITHUB_TOKEN to raise it)"
		fi
		die "could not fetch ${url}: HTTP ${status}${hint}"
	fi
	cat "$body"
}

# Download $1 to $2 via a .part file, then check size $3 and digest $4 before
# renaming it into place, so a failed or corrupt download never looks done.
download() {
	local url="$1" dest="$2" size="$3" digest="$4" protos part received actual
	protos="$(allowed_protocols "$url")" ||
		die "refusing to download non-HTTPS URL ${url}"
	part="${dest}.part"

	local progress=(-sS)
	[[ -t 2 ]] && progress=(--progress-bar)
	# curl follows redirects (GitHub sends downloads to its CDN); --proto-redir
	# makes sure none of them downgrade to plain HTTP.
	if ! curl -fL "${progress[@]}" \
		--proto "$protos" --proto-redir "$protos" --max-redirs 5 \
		--retry 3 --retry-delay 2 --connect-timeout 15 \
		"$url" -o "$part"; then
		rm -f "$part"
		die "download of ${url} failed"
	fi

	received="$(wc -c <"$part" | tr -d ' ')"
	if [[ $received != "$size" ]]; then
		rm -f "$part"
		die "size mismatch for ${dest##*/}: expected ${size}, got ${received}"
	fi
	actual="$(sha256_of "$part")"
	if [[ $actual != "$digest" ]]; then
		rm -f "$part"
		die "checksum mismatch for ${dest##*/}
  expected ${digest}
  actual   ${actual}"
	fi
	mv -f "$part" "$dest"
}

# --- main --------------------------------------------------------------------

if $all; then
	targets=("${ALL_TARGETS[@]}")
else
	targets=("$(detect_target)")
fi

echo "Fetching latest Bun release..."
release="$(get_json "$API_URL")"

tag="$(jq -r '.tag_name // empty' <<<"$release")"
if [[ "$(jq -r '(.draft // false) or (.prerelease // false)' <<<"$release")" == true ]]; then
	die "${tag} is not a stable release"
fi
# "bun-v1.4.5" → "1.4.5"
version="${tag#bun-v}"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "could not resolve version from tag '${tag}'"

# Fetched only if some asset lacks GitHub's own digest field.
shasums=""

for target in "${targets[@]}"; do
	name="bun-${target}.zip"
	asset="$(jq -c --arg n "$name" '.assets[]? | select(.name == $n)' <<<"$release")"
	[[ -n $asset ]] || die "release ${tag} has no ${name}"
	url="$(jq -r '.browser_download_url' <<<"$asset")"
	size="$(jq -r '.size' <<<"$asset")"
	digest="$(jq -r '.digest // ""' <<<"$asset")"
	digest="${digest#sha256:}"

	# Failing GitHub's digest, check against the release's SHASUMS256.txt.
	if [[ ! $digest =~ ^[0-9a-f]{64}$ ]]; then
		if [[ -z $shasums ]]; then
			sums_url="$(jq -r '.assets[]? | select(.name == "SHASUMS256.txt") | .browser_download_url' <<<"$release")"
			[[ -n $sums_url ]] || die "release ${tag} publishes no checksum"
			sums_protos="$(allowed_protocols "$sums_url")" ||
				die "refusing to download non-HTTPS URL ${sums_url}"
			shasums="$(curl -fsSL --proto "$sums_protos" --proto-redir "$sums_protos" \
				--connect-timeout 10 --max-time 30 "$sums_url")" ||
				die "could not fetch ${sums_url}"
		fi
		digest="$(awk -v n="$name" '{ sub(/\r$/, "") }
			$1 ~ /^[0-9a-f]{64}$/ && ($2 == n || $2 == "*" n) { print $1; exit }' <<<"$shasums")"
		[[ -n $digest ]] || die "SHASUMS256.txt has no entry for ${name}"
	fi

	# Keep the version in the local name; the asset name alone doesn't have it.
	file="bun-v${version}-${target}.zip"
	echo "Bun ${version} for ${target}: ${file} ($(((size + MIB / 2) / MIB)) MiB)"

	if [[ -f $file && "$(sha256_of "$file")" == "$digest" ]]; then
		echo "  already downloaded and verified, skipping"
	else
		download "$url" "$file" "$size" "$digest"
		echo "  verified ${digest}"
	fi
	echo "Saved ${PWD}/${file}"
done
