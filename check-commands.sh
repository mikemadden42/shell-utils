#!/bin/bash

commands=("ls" "git" "foo" "bar")

available_commands=()
unavailable_commands=()

for command in "${commands[@]}"; do
	if command -v "$command" &>/dev/null; then
		available_commands+=("$command")
	else
		unavailable_commands+=("$command")
	fi
done

if [[ ${#available_commands[@]} -gt 0 ]]; then
	echo "Available commands:"
	echo "${available_commands[@]}"
fi

if [[ ${#unavailable_commands[@]} -gt 0 ]]; then
	echo "Unavailable commands:"
	echo "${unavailable_commands[@]}"
fi
