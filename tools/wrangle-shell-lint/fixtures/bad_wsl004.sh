#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input
# Uses single-bracket [ ] — WSL004 positive fixture.

if [ -n "$1" ]; then
    printf 'found: %s\n' "$1"
fi
