#!/bin/bash
set -e

# Example usage:
# ./run.sh

if [ ! -d "debug" ]; then
    echo "Creating debug folder..."
    mkdir -p debug
fi

echo "Running fast-fuzzy-matcher..."
odin run src/ -out:debug/ffm -collection:app=src -sanitize:address -debug -show-timings
