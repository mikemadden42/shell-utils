#!/bin/bash

if [ "$(uname)" != "Darwin" ]; then
	echo "Error: this script only runs on macOS."
	exit 1
fi

cycle_count=$(ioreg -r -c AppleSmartBattery | awk -F'= ' '/^[[:space:]]*"CycleCount"[[:space:]]*=/ {print $2; exit}')

if [ -z "$cycle_count" ]; then
	echo "Error: could not read battery cycle count."
	exit 1
fi

echo "Cycle Count: $cycle_count"
