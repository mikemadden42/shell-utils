#!/bin/sh

for i in clang clang++ make git perl python3 swift; do
	$i --version 2>&1
	echo
done >~/devtools.txt
