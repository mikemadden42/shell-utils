#!/bin/sh

if [ "$1" = "" ]; then
	echo "usage: $0 <filename.toc>"
	exit 1
fi

if [ ! -f "$1" ]; then
	echo "Error: file $1 does not exist."
fi

cdrdao write --eject --device /dev/sr0 --driver generic-mmc-raw "$1"
