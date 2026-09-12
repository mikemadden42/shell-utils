#!/usr/bin/env bash
set -euo pipefail

# Prints the Claude Code version each release channel currently points at.
# Each channel is a plain-text object in the release bucket holding a single
# version string, the same lookup download-claude-code.bash does to resolve a
# channel name.
#
# Usage: claude-code-versions.bash [CHANNEL...]   (defaults to stable latest)

BASE_URL="${CLAUDE_CODE_RELEASES_BASE_URL:-https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases}"

command -v curl >/dev/null ||
	{
		echo "Error: required command not found: curl" >&2
		exit 1
	}

is_version() {
	[[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]
}

if (($# == 0)); then
	set -- stable latest
fi

status=0
for channel in "$@"; do
	if [[ ! $channel =~ ^[a-z][a-z0-9-]*$ ]]; then
		echo "Error: invalid channel name '${channel}'." >&2
		status=1
		continue
	fi

	if ! version="$(curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/${channel}" 2>/dev/null)"; then
		echo "Error: could not fetch channel '${channel}'." >&2
		status=1
		continue
	fi
	version="${version//[$'\r\n\t ']/}"

	if ! is_version "$version"; then
		echo "Error: channel '${channel}' resolved to invalid version '${version}'." >&2
		status=1
		continue
	fi

	printf '%-8s %s\n' "$channel" "$version"
done

exit "$status"
