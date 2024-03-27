#!/bin/bash

# Change false to the program you want to run & check.
until false; do
	echo "Trying again..."
	sleep $((RANDOM % 10 + 1)) # Generate random sleep time (1-10 seconds)
done
echo "Program succeeded!"
