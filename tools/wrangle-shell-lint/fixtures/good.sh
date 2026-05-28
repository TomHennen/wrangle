#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input

# A clean script that complies with all wrangle shell style rules.
# Used as the negative fixture in tests — the linter must produce no findings.

for item in "$@"; do
    printf 'item: %s\n' "$item"
done
