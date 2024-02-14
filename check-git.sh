#!/bin/sh

for i in *; do
	if [ -d "$i" ]; then
		if [ ! -d "$i/.git" ]; then
			echo "$i does not contain a .git folder"
		fi
	fi
done
