#!/bin/sh

for i in *.tar *.tgz *.txz *.zip; do
	if [ ! -f "$i.sha256" ]; then
		echo "Creating sha256 for '$i'..."
		sha256sum "$i" >"$i.sha256"
	fi
done
