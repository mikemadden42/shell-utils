#!/usr/bin/env bash
set -euo pipefail

# Removes a Codex CLI installed by install-codex.bash (or the official
# install.sh, which uses the same layout).
#
# By default this removes only what the installer created: the standalone
# package tree under ~/.codex/packages/standalone and the symlinks in
# ~/.local/bin. Your Codex config, credentials, and history in ~/.codex are
# left alone, because losing auth.json means signing in again. Pass --purge to
# delete all of ~/.codex as well.
#
# Usage: uninstall-codex.bash [--purge] [--dry-run] [--yes]

BIN_DIR="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
STANDALONE_ROOT="$CODEX_HOME_DIR/packages/standalone"

purge=false
dry_run=false
assume_yes=false

while (($#)); do
	case "$1" in
	--purge) purge=true ;;
	--dry-run | -n) dry_run=true ;;
	--yes | -y) assume_yes=true ;;
	--help | -h)
		awk 'NR > 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
		exit 0
		;;
	*)
		echo "Error: unknown argument '$1'. See --help." >&2
		exit 1
		;;
	esac
	shift
done

# Only remove links that point into the standalone tree; a codex installed by
# brew, npm, or bun is somebody else's to uninstall.
owned_link() {
	local link="$1" dest
	[[ -L $link ]] || return 1
	dest="$(readlink "$link")"
	[[ $dest == "$STANDALONE_ROOT"/* ]]
}

targets=()
for link in "$BIN_DIR/codex" "$BIN_DIR/codex-code-mode-host"; do
	if owned_link "$link"; then
		targets+=("$link")
	elif [[ -e $link ]]; then
		echo "Leaving ${link} alone: it was not created by install-codex.bash."
	fi
done

if $purge; then
	if [[ -e $CODEX_HOME_DIR ]]; then
		targets+=("$CODEX_HOME_DIR")
	fi
elif [[ -e $STANDALONE_ROOT ]]; then
	targets+=("$STANDALONE_ROOT")
fi

if ((${#targets[@]} == 0)); then
	echo "Nothing to remove; no Codex standalone install found."
	exit 0
fi

version="$("$STANDALONE_ROOT/current/bin/codex" --version 2>/dev/null | awk '{print $NF}' || true)"
if [[ -n $version ]]; then
	echo "Found Codex CLI ${version}"
fi

echo "The following will be removed:"
for t in "${targets[@]}"; do
	if [[ -L $t ]]; then
		echo "  ${t} -> $(readlink "$t")"
	else
		echo "  ${t}  ($(du -sh "$t" 2>/dev/null | cut -f1))"
	fi
done
if $purge; then
	echo "  (--purge: this includes your Codex config, credentials, and history)"
fi

if $dry_run; then
	echo
	echo "Dry run; nothing was removed."
	exit 0
fi

if ! $assume_yes; then
	read -r -p "Remove these? [y/N] " answer
	case "$answer" in
	y | Y | yes | YES) ;;
	*)
		echo "Aborted; nothing was removed."
		exit 1
		;;
	esac
fi

for t in "${targets[@]}"; do
	rm -rf "$t"
	echo "Removed ${t}"
done

# Without --purge the packages/ directory is left behind empty; tidy it up, but
# only if nothing else moved in there.
rmdir "$CODEX_HOME_DIR/packages" 2>/dev/null || true

# The official install.sh appends a PATH block to a shell profile. Point at it
# rather than editing the file, since people often add their own lines nearby.
for profile in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
	if [[ -f $profile ]] && grep -Fq "# >>> Codex installer >>>" "$profile"; then
		echo "Note: ${profile} still has a Codex installer PATH block; remove it by hand."
	fi
done

if remaining="$(command -v codex 2>/dev/null)"; then
	echo "Note: another codex is still on your PATH at ${remaining}"
fi
