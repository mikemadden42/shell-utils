#!/usr/bin/env bash
set -euo pipefail

# Prints the Codex CLI version each release channel currently points at.
# Each channel is a release-metadata JSON document on releases.openai.com; the
# version is its tag_name without the rust-v prefix, the same lookup
# download-codex.bash does for latest.
#
# latest is the current stable release. prerelease tracks the newest alpha; it
# is not documented and the official install.sh never reads it, so it may move
# or disappear.
#
# Usage: codex-versions.bash [CHANNEL...]   (defaults to latest prerelease)

BASE_URL="${CODEX_RELEASES_BASE_URL:-https://releases.openai.com/codex}"

for required in curl jq; do
	command -v "$required" >/dev/null ||
		{
			echo "Error: required command not found: ${required}" >&2
			exit 1
		}
done

is_version() {
	[[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]
}

if (($# == 0)); then
	set -- latest prerelease
fi

status=0
for channel in "$@"; do
	if [[ ! $channel =~ ^[a-z][a-z0-9-]*$ ]]; then
		echo "Error: invalid channel name '${channel}'." >&2
		status=1
		continue
	fi

	if ! metadata="$(curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/channels/${channel}" 2>/dev/null)"; then
		echo "Error: could not fetch channel '${channel}'." >&2
		status=1
		continue
	fi

	# tag_name looks like rust-v0.154.0; the release version is the part after it.
	tag="$(jq -r '.tag_name // empty' <<<"$metadata" 2>/dev/null || true)"
	version="${tag#rust-v}"

	if [[ $tag != rust-v* ]] || ! is_version "$version"; then
		echo "Error: channel '${channel}' resolved to invalid tag '${tag}'." >&2
		status=1
		continue
	fi

	printf '%-11s %s\n' "$channel" "$version"
done

exit "$status"
