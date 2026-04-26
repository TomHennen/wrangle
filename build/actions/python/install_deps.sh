#!/bin/bash
# Installs the project's dependencies for the python build action.
# Two paths:
#   - uv: `uv sync` (called by the action when uv.lock is present)
#   - pip: try [test] extra, then [dev] extra, then bare install
#
# Usage: build/actions/python/install_deps.sh <path> <use_uv>
#   path:    project directory (already validated)
#   use_uv:  "true" for the uv path, anything else for pip

set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <path> <use_uv>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
USE_UV="$2"

cd "$INPUT_PATH"

if [[ "$USE_UV" == "true" ]]; then
    uv sync
    exit 0
fi

python -m pip install --upgrade pip
if python -m pip install -e ".[test]" 2>/dev/null; then
    printf 'Installed with [test] extra\n'
elif python -m pip install -e ".[dev]" 2>/dev/null; then
    printf 'Installed with [dev] extra\n'
else
    python -m pip install -e .
    printf 'Installed without test extras\n'
fi
