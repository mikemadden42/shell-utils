#!/usr/bin/env bash
set -euo pipefail

# Mirrors the Anthropic Claude desktop app installers. The download page hands
# each platform a /api/desktop/<platform>/<arch>/<kind>/latest/redirect URL that
# 307s to the real artifact on downloads.claude.ai; this resolves every target
# into claude-desktop-<version>/ and verifies each download.
#
# Unlike download-claude-code.bash there is no manifest and no published
# checksum file, so the targets are a list rather than something derivable. The
# integrity checks are what the CDN itself advertises: the byte length, and the
# ETag, which for these objects is the MD5 of the content. That catches
# truncation and corruption, not substitution.
#
# Usage: download-claude-desktop.bash [--dry-run] [TARGET...]
#   TARGET is platform/arch/kind, e.g. darwin/universal/pkg (default: the three
#   the download page offers). darwin/universal/dmg also exists.

DEFAULT_TARGETS=(
	darwin/universal/pkg
	win32/x64/msix
	win32/arm64/msix
)
API_BASE="${CLAUDE_DESKTOP_API_BASE_URL:-https://claude.ai/api/desktop}"
CHANNEL="${CLAUDE_DESKTOP_RELEASE:-latest}"

command -v curl >/dev/null ||
	{
		echo "Error: required command not found: curl" >&2
		exit 1
	}

if command -v sha256sum >/dev/null; then
	sha256=(sha256sum)
else
	sha256=(shasum -a 256)
fi

if command -v md5sum >/dev/null; then
	md5=(md5sum)
elif command -v md5 >/dev/null; then
	md5=(md5 -q)
else
	md5=()
fi

sha256_of() {
	local out
	out="$("${sha256[@]}" "$1")" || return 1
	printf '%s' "${out%% *}"
}

md5_of() {
	local out
	((${#md5[@]})) || return 1
	out="$("${md5[@]}" "$1")" || return 1
	printf '%s' "${out%% *}"
}

dry_run=false
targets=()
while (($#)); do
	case "$1" in
	--dry-run | -n) dry_run=true ;;
	-*)
		echo "Error: unknown option '$1'." >&2
		exit 1
		;;
	*)
		if [[ ! $1 =~ ^[a-z0-9]+/[a-z0-9]+/[a-z0-9]+$ ]]; then
			echo "Error: invalid target '$1'. Expected platform/arch/kind." >&2
			exit 1
		fi
		targets+=("$1")
		;;
	esac
	shift
done
((${#targets[@]})) || targets=("${DEFAULT_TARGETS[@]}")

# Ask the CDN for an object's size and ETag without fetching it. A one-byte
# range keeps this cheap while still proving the object is really there.
probe() {
	curl -sS -r 0-0 -D - -o /dev/null \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
		--connect-timeout 15 --max-time 60 "$1" 2>/dev/null | tr -d '\r'
}

version=""
build=""
declare -A url_of=()
unresolved=()

echo "Resolving ${#targets[@]} targets (${CHANNEL})..."

for target in "${targets[@]}"; do
	url="$(curl -sS -o /dev/null -w '%{redirect_url}' \
		--proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 \
		"${API_BASE}/${target}/${CHANNEL}/redirect" 2>/dev/null || true)"

	# The redirect path carries the release: .../releases/<platform>/<arch>/<version>/Claude-<build>.<ext>
	if [[ $url =~ /releases/[a-z0-9]+/[a-z0-9]+/([0-9][0-9A-Za-z.-]*)/Claude-([0-9a-f]+)\.[a-z0-9]+$ ]]; then
		this_version="${BASH_REMATCH[1]}"
		this_build="${BASH_REMATCH[2]}"
		if [[ -z $version ]]; then
			version="$this_version"
			build="$this_build"
		elif [[ $this_version != "$version" || $this_build != "$build" ]]; then
			echo "Error: ${target} resolved to ${this_version} (build ${this_build}), but an earlier target resolved to ${version} (build ${build})." >&2
			echo "  a release is probably mid-rollout; pass one target at a time to mirror them separately." >&2
			exit 1
		fi
		echo "  ${target} -> ${this_version}"
		url_of["$target"]="$url"
	else
		echo "  ${target} -> could not resolve"
		unresolved+=("$target")
	fi
done

# claude.ai sits behind a bot challenge that answers some clients with a 403
# instead of the redirect. Every target in a release shares one version and
# build id, so a target that failed can still be addressed directly on the CDN
# once any other target has resolved -- confirmed against the CDN before use,
# so a wrong guess is reported rather than downloaded.
if ((${#unresolved[@]})) && [[ -n $version ]]; then
	echo "Deriving ${#unresolved[@]} unresolved targets from ${version} (build ${build})..."
	for target in "${unresolved[@]}"; do
		IFS=/ read -r platform arch kind <<<"$target"
		url="https://downloads.claude.ai/releases/${platform}/${arch}/${version}/Claude-${build}.${kind}"
		if probe "$url" | grep -qiE '^HTTP/[0-9.]+ 20[06]'; then
			echo "  ${target} -> ${url##*/}"
			url_of["$target"]="$url"
		else
			echo "Error: ${target} is not published at ${url}" >&2
			exit 1
		fi
	done
fi

if ((${#url_of[@]} == 0)); then
	echo "Error: no target resolved. claude.ai may be challenging this client; try again or from another network." >&2
	exit 1
fi

echo "Mirroring Claude desktop ${version} (build ${build})..."

outdir="claude-desktop-${version}"
sums_file="claude-desktop-${version}-sha256sums.txt"

if ! $dry_run; then
	mkdir -p "$outdir"
	cd "$outdir"
	: >"$sums_file"
fi

for target in "${targets[@]}"; do
	url="${url_of[$target]}"
	IFS=/ read -r platform arch kind <<<"$target"
	file="claude-desktop-${version}-${platform}-${arch}.${kind}"

	headers="$(probe "$url")"
	# content-range is "bytes 0-0/<total>"; the total after the slash is the size.
	size="$(awk 'tolower($1) == "content-range:" { n = split($0, a, "/"); print a[n]; exit }' <<<"$headers")"
	etag="$(awk 'tolower($1) == "etag:" { gsub(/"/, "", $2); print $2; exit }' <<<"$headers")"
	if [[ ! $size =~ ^[0-9]+$ ]]; then
		echo "Error: ${target} did not report a size." >&2
		exit 1
	fi

	printf '[%s] %s (%s MiB)\n' "$target" "$file" "$((size / 1048576))"

	if $dry_run; then
		echo "  ${url}"
		continue
	fi

	# A complete file is only skipped when its length and, when the CDN gives a
	# usable one, its MD5 still match what is published.
	if [[ -f $file && "$(wc -c <"$file" | tr -dc '0-9')" == "$size" ]] &&
		{ [[ ! $etag =~ ^[0-9a-f]{32}$ ]] || [[ "$(md5_of "$file" || true)" == "$etag" ]]; }; then
		echo "  already complete, skipping"
		printf '%s  %s\n' "$(sha256_of "$file")" "$file" >>"$sums_file"
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

	# A multipart upload's ETag ends in -<n> and is not an MD5; skip those
	# rather than reporting a mismatch that means nothing.
	if [[ $etag =~ ^[0-9a-f]{32}$ ]]; then
		if ((${#md5[@]} == 0)); then
			echo "  no md5 tool; size verified only"
		else
			actual_md5="$(md5_of "$file")"
			if [[ $actual_md5 != "$etag" ]]; then
				echo "Error: ETag mismatch for ${file}" >&2
				echo "  expected ${etag}" >&2
				echo "  actual   ${actual_md5}" >&2
				echo "  delete the file and re-run to download it fresh." >&2
				exit 1
			fi
			echo "  verified md5 ${etag} and ${size} bytes"
		fi
	else
		echo "  no usable ETag; verified ${size} bytes"
	fi

	printf '%s  %s\n' "$(sha256_of "$file")" "$file" >>"$sums_file"
done

if $dry_run; then
	echo
	echo "Dry run; nothing was downloaded."
	exit 0
fi

echo
echo "Locally computed SHA256 sums written to ${outdir}/${sums_file}"
echo "Anthropic publishes no checksums for these installers; the sums are this"
echo "mirror's own, not an upstream attestation."
cat "$sums_file"
