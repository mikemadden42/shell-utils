#!/bin/sh

for i in baseboard-manufacturer system-version system-product-name chassis-type system-serial-number bios-release-date bios-version; do
	echo "$i : $(sudo dmidecode -s $i)"
done
echo

sudo inxi -M
