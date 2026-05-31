#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input

# WSL007 positive fixture: a top-level `set +f` with no subshell. Under
# set -e, an abort before the restoring `set -f` leaks glob-enabled
# state to the rest of the script. The compliant form confines the glob
# to a `( … )` subshell.
set +f
shopt -s nullglob
for f in ./*.conf; do
    printf '%s\n' "$f"
done
set -f
