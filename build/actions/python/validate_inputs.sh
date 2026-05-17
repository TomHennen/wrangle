#!/bin/bash
# Validates inputs to the python build action: shared path checks via
# lib/validate_path.sh, plus a python-specific check that pyproject.toml
# exists at the resolved path. pyproject.toml is required (PEP 621) —
# the action reads python-version from it via actions/setup-python's
# python-version-file, so legacy setup.py-only projects aren't supported.
#
# Usage: build/actions/python/validate_inputs.sh <path> <cache>

set -euo pipefail
set -f  # disable globbing — processes external input

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <path> <cache>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
INPUT_CACHE="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reject any cache value that is not the exact enabled|disabled allowlist.
# This is load-bearing for SLSA L3: the reusable workflow passes
# cache=disabled for release builds, and a typo there must fail the build
# loudly rather than silently leave the uv cache on (which would downgrade
# the release build from Build L3 to Build L2). See docs/SLSA_L3_AUDIT.md
# Finding 1.
if [[ ! "$INPUT_CACHE" =~ ^(enabled|disabled)$ ]]; then
    printf 'Error: invalid cache value: %s (expected "enabled" or "disabled")\n' "$INPUT_CACHE" >&2
    exit 1
fi

"$SCRIPT_DIR/../../../lib/validate_path.sh" "$INPUT_PATH"

if [[ ! -f "$INPUT_PATH/pyproject.toml" ]]; then
    printf 'Error: no pyproject.toml found in %s\n' "$INPUT_PATH" >&2
    printf 'Hint: setup.py-only projects are not supported. Add a minimal pyproject.toml — see https://packaging.python.org/en/latest/guides/writing-pyproject-toml/\n' >&2
    exit 1
fi
