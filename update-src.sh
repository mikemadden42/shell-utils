#!/bin/sh

for i in *; do
	printf "####\n%s\n" "$i"
	cd "$i" || exit
	git pull --rebase
	cd ..
	# printf "####\n"
done
