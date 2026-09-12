#!/usr/bin/env bash
set -euo pipefail

# Installs the OpenAI Codex CLI from its standalone package archive.
#
# The tarball cannot simply be unpacked onto $PATH: codex locates its helper
# binaries (codex-code-mode-host, rg, and bwrap on Linux) relative to its own
# directory, so the package has to keep its layout. This reproduces what the
# official install.sh does — unpack the package into
# ~/.codex/packages/standalone/releases/<version>-<target>/, repoint the
# "current" symlink at it, and link ~/.local/bin/codex into that tree — so
# upgrades are atomic and old releases stay around to roll back to.
#
# Usage: install-codex.bash [VERSION]   (VERSION defaults to latest)

VERSION_INPUT="${1:-${CODEX_RELEASE:-latest}}"
BASE_URL="${CODEX_RELEASES_BASE_URL:-https://releases.openai.com/codex}"
BIN_DIR="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
STANDALONE_ROOT="$CODEX_HOME_DIR/packages/standalone"
RELEASES_DIR="$STANDALONE_ROOT/releases"
CURRENT_LINK="$STANDALONE_ROOT/current"

for required in curl jq tar; do
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

# Verify $1 against digest $2, reporting both sides on a mismatch.
verify() {
	local file="$1" expected="$2" actual
	actual="$(sha256_of "$file")"
	if [[ $actual != "$expected" ]]; then
		echo "Error: checksum mismatch for $(basename "$file")" >&2
		echo "  expected ${expected}" >&2
		echo "  actual   ${actual}" >&2
		return 1
	fi
}

# The package archives are built against musl on Linux and ship per-arch on
# macOS; Rosetta-translated shells get the native arm64 build.
case "$(uname -s)" in
Darwin) os=darwin ;;
Linux) os=linux ;;
*)
	echo "Error: only macOS and Linux are supported." >&2
	exit 1
	;;
esac

case "$(uname -m)" in
x86_64 | amd64) arch=x86_64 ;;
arm64 | aarch64) arch=aarch64 ;;
*)
	echo "Error: unsupported architecture: $(uname -m)" >&2
	exit 1
	;;
esac

if [[ $os == darwin && $arch == x86_64 &&
	"$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then
	arch=aarch64
fi

if [[ $os == darwin ]]; then
	target="${arch}-apple-darwin"
else
	target="${arch}-unknown-linux-musl"
fi

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

echo "==> Fetching release metadata (${version})..."
metadata="$(curl -fsSL --connect-timeout 10 --max-time 30 "$metadata_url")"

# tag_name looks like rust-v0.154.0; the release version is the part after it.
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

asset="codex-package-${target}.tar.gz"
sums_asset="codex-package_SHA256SUMS"

asset_digest() {
	local digest
	digest="$(jq -r --arg n "$1" '.assets[] | select(.name == $n) | .digest // empty' <<<"$metadata")"
	digest="${digest#sha256:}"
	if [[ ! $digest =~ ^[0-9a-f]{64}$ ]]; then
		echo "Error: release ${VERSION} does not publish ${1}." >&2
		return 1
	fi
	printf '%s' "$digest"
}

asset_url() {
	jq -r --arg n "$1" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$metadata"
}

release_name="${VERSION}-${target}"
release_dir="$RELEASES_DIR/$release_name"

echo "==> Installing Codex CLI ${VERSION} (${target})"

tmp_dir="$(mktemp -d)"
stage_release="$RELEASES_DIR/.staging.${release_name}.$$"
cleanup() {
	rm -rf "$tmp_dir" "$stage_release"
}
trap cleanup EXIT INT TERM

mkdir -p "$RELEASES_DIR"

# The release metadata signs the checksum manifest, and the manifest carries the
# archive's digest, so both hops are verified before anything is unpacked.
sums_path="$tmp_dir/$sums_asset"
curl -fsSL --connect-timeout 15 --max-time 60 "$(asset_url "$sums_asset")" -o "$sums_path"
verify "$sums_path" "$(asset_digest "$sums_asset")"

digest="$(awk -v a="$asset" '$2 == a && length($1) == 64 { print tolower($1); found = 1; exit }
	END { if (!found) exit 1 }' "$sums_path")" ||
	{
		echo "Error: ${asset} is not listed in ${sums_asset}." >&2
		exit 1
	}

# Reuse a mirror made by download-codex.bash when it is sitting alongside us,
# so installing after a mirror run does not refetch several hundred megabytes.
archive_path="$tmp_dir/$asset"
mirrored="codex-${VERSION}/${asset}"
if [[ -f $mirrored && "$(sha256_of "$mirrored")" == "$digest" ]]; then
	echo "==> Using mirrored archive ${mirrored}"
	archive_path="$mirrored"
else
	echo "==> Downloading ${asset}"
	curl -fL --progress-bar -R \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
		--retry 3 --retry-delay 2 --connect-timeout 15 \
		"$(asset_url "$asset")" -o "$archive_path"
	verify "$archive_path" "$digest"
fi

echo "==> Unpacking to ${release_dir}"
mkdir -p "$stage_release"
tar -xzf "$archive_path" -C "$stage_release"

# The archive does not carry the executable bit for every helper, and codex
# refuses to start without them.
chmod 0755 \
	"$stage_release/bin/codex" \
	"$stage_release/bin/codex-code-mode-host" \
	"$stage_release/codex-path/rg"
if [[ -f $stage_release/codex-resources/bwrap ]]; then
	chmod 0755 "$stage_release/codex-resources/bwrap"
fi
ln -sf "bin/codex" "$stage_release/codex"

rm -rf "$release_dir"
mv "$stage_release" "$release_dir"

installed="$("$release_dir/bin/codex" --version 2>/dev/null | awk '{print $NF}')"
if [[ $installed != "$VERSION" ]]; then
	echo "Error: unpacked codex reports version '${installed}', expected ${VERSION}." >&2
	exit 1
fi

# Swap both symlinks through a temporary name so a failed install never leaves
# ~/.local/bin/codex dangling.
relink() {
	local link="$1" target="$2" tmp="${1}.$$"
	rm -f "$tmp"
	ln -s "$target" "$tmp"
	# -T is GNU, -h is BSD: both mean "replace the symlink, do not follow it".
	mv -Tf "$tmp" "$link" 2>/dev/null && return
	mv -hf "$tmp" "$link" 2>/dev/null && return
	rm -rf "$link"
	mv "$tmp" "$link"
}

relink "$CURRENT_LINK" "$release_dir"

mkdir -p "$BIN_DIR"
relink "$BIN_DIR/codex" "$CURRENT_LINK/bin/codex"

# Only macOS looks up codex-code-mode-host on PATH; elsewhere codex finds it
# next to itself, so an extra link would just go stale.
if [[ $os == darwin ]]; then
	relink "$BIN_DIR/codex-code-mode-host" "$CURRENT_LINK/bin/codex-code-mode-host"
elif [[ "$(readlink "$BIN_DIR/codex-code-mode-host" 2>/dev/null || true)" == "$CURRENT_LINK/bin/codex-code-mode-host" ]]; then
	rm -f "$BIN_DIR/codex-code-mode-host"
fi

"$BIN_DIR/codex" --version >/dev/null

echo
echo "Codex CLI ${VERSION} installed to ${BIN_DIR}/codex"
case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*)
	echo "${BIN_DIR} is not on your PATH; add it with:"
	echo "  export PATH=\"${BIN_DIR}:\$PATH\""
	;;
esac

echo "Previous releases are kept in ${RELEASES_DIR}; remove old ones by hand."
