#!/bin/bash
# Validates inputs to the python build action: shared path checks via
# lib/validate_path.sh, plus a python-specific check that pyproject.toml
# (or legacy setup.py) exists at the resolved path.
#
# Usage: build/actions/python/validate_inputs.sh <path>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <path>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/../../../lib/validate_path.sh" "$INPUT_PATH"

if [[ ! -f "$INPUT_PATH/pyproject.toml" ]]; then
    if [[ -f "$INPUT_PATH/setup.py" ]]; then
        printf 'Warning: using legacy setup.py (pyproject.toml preferred)\n'
    else
        printf 'Error: no pyproject.toml or setup.py found in %s\n' "$INPUT_PATH" >&2
        exit 1
    fi
fi
