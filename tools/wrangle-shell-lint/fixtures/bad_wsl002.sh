#!/bin/bash
set -euo pipefail
# Missing set -f — iterates over "$@" — WSL002 positive fixture.

for item in "$@"; do
    printf '%s\n' "$item"
done
