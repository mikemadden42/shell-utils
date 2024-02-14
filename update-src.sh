#!/bin/sh

for i in *; do
	echo "####\n$i"
	cd $i
	git pull --rebase
	cd ..
	echo "####\n"
done
