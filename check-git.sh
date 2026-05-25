#!/bin/sh

for i in *; do
	[ -d "$i" ] || continue

	if [ ! -d "$i/.git" ]; then
		echo "$i does not contain a .git folder"
		continue
	fi

	if [ -n "$(git -C "$i" status --porcelain)" ]; then
		echo "$i has uncommitted changes"
	fi

	if ! git -C "$i" symbolic-ref -q HEAD >/dev/null; then
		echo "$i is in detached HEAD state"
	elif ! git -C "$i" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
		echo "$i has no upstream configured"
	else
		if [ -n "$(git -C "$i" log '@{u}..HEAD' 2>/dev/null)" ]; then
			echo "$i has unpushed commits"
		fi
		if [ -n "$(git -C "$i" log 'HEAD..@{u}' 2>/dev/null)" ]; then
			echo "$i is behind upstream"
		fi
	fi

	if [ -n "$(git -C "$i" stash list)" ]; then
		echo "$i has stashes"
	fi
done
