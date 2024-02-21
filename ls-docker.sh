#!/bin/sh

for i in docker docker-compose; do
	$i --version 2>&1
	echo
done >~/docker.txt
