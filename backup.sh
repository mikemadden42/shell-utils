#!/bin/sh -x

NOW=$(date +%Y-%m-%d-%H-%M)
cd "$HOME/.." || exit
tar --exclude --exclude "$USER/.cargo" --exclude "$USER/.rustup" -cvJf "/tmp/$USER-$NOW.txz" "$USER"

cd /tmp || exit
sha256sum "$USER-$NOW.txz" >"$USER-$NOW.txz.sha256"
