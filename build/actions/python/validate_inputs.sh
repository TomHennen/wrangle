#!/bin/bash
# Validates inputs to the python build action: shared path checks via
# lib/validate_path.sh, plus a python-specific check that pyproject.toml
# exists at the resolved path. pyproject.toml is required (PEP 621) —
# the action reads python-version from it via actions/setup-python's
# python-version-file, so legacy setup.py-only projects aren't supported.
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
    printf 'Error: no pyproject.toml found in %s\n' "$INPUT_PATH" >&2
    printf 'Hint: setup.py-only projects are not supported. Add a minimal pyproject.toml — see https://packaging.python.org/en/latest/guides/writing-pyproject-toml/\n' >&2
    exit 1
fi
