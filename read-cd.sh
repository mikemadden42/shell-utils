#!/bin/sh

cdrdao read-cd --read-raw --datafile "$1.bin" --device /dev/sr0 --driver generic-mmc-raw "$1.toc"
