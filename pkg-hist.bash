#!/bin/bash

dpkg_dir=$(mktemp -d)
apt_dir=$(mktemp -d)
trap 'rm -rf "$dpkg_dir" "$apt_dir"' EXIT

########

rsync -av /var/log/dpkg.log* "$dpkg_dir"
pushd "$dpkg_dir" || exit
gunzip -- *.gz
# shellcheck disable=SC2045
for f in $(ls -rt); do
	grep -E 'install|remove' "$f" >>"$HOME/hist.log"
done
popd || exit

sort -u "$HOME/hist.log" >"$HOME/dpkg_history.log" && rm "$HOME/hist.log"

########

rsync -av /var/log/apt/history.log* "$apt_dir"
pushd "$apt_dir" || exit
gunzip -- *.gz
# shellcheck disable=SC2045
for f in $(ls -rt); do
	cat "$f" >>"$HOME/hist.log"
done
popd || exit

mv "$HOME/hist.log" "$HOME/apt_history.log"

########
