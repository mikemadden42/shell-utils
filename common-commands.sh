#!/bin/sh

history | awk '{print $2}' | sort | uniq -c | sort -rn | head -20
