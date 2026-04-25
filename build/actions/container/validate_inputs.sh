#!/bin/bash
# Validates inputs to the container build action and writes normalized
# values to GITHUB_OUTPUT (path, lowercased imagename, shortname for
# artifact namespacing).
#
# Path validation is delegated to lib/validate_path.sh. Registry and
# imagename are checked here against narrow allowlists because they
# are container-specific.
#
# Usage: build/actions/container/validate_inputs.sh <path> <registry> <imagename>

set -euo pipefail
set -f  # disable globbing — processes external input

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s <path> <registry> <imagename>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
INPUT_REGISTRY="$2"
INPUT_IMAGENAME="$3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/../../../lib/validate_path.sh" "$INPUT_PATH"

if [[ ! "$INPUT_REGISTRY" =~ ^[a-z0-9.-]+$ ]]; then
    printf 'Error: invalid registry: %s\n' "$INPUT_REGISTRY" >&2
    exit 1
fi
if [[ ! "$INPUT_IMAGENAME" =~ ^[a-z0-9./:_-]+$ ]]; then
    printf 'Error: invalid image name: %s\n' "$INPUT_IMAGENAME" >&2
    exit 1
fi

{
    printf 'imagename=%s\n' "${INPUT_IMAGENAME,,}"
    printf 'path=%s\n' "$INPUT_PATH"
    printf 'shortname=%s\n' "${INPUT_PATH////_}"
} >> "$GITHUB_OUTPUT"
