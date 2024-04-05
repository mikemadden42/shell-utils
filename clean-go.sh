#!/bin/sh

echo "Cleaning cache..."
go clean -cache
echo "Cleaning modcache..."
go clean -modcache
echo "Cleaning testcache..."
go clean -testcache
echo "Cleaning fuzzcache..."
go clean -fuzzcache
