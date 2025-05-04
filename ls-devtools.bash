#!/bin/bash

SYSTEM=$(uname -s)

if [ "$SYSTEM" == "Linux" ]; then
	TOOLS="gcc g++ clang clang++ make cmake git perl python3"
else
	TOOLS="clang clang++ make cmake git perl python3 swift"
fi

for i in $TOOLS; do
	$i --version 2>&1
	echo
done >~/devtools.txt
