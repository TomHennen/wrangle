#!/bin/bash
# Validates inputs to the container build action and writes normalized
# values to GITHUB_OUTPUT (path, lowercased imagename, shortname for
# artifact namespacing).
#
# Path validation is delegated to lib/validate_path.sh. Registry and
# imagename are checked here against narrow allowlists because they
# are container-specific.
#
# Usage: build/actions/container/validate_inputs.sh <path> <registry> <imagename> <cache>

set -euo pipefail
set -f  # disable globbing — processes external input

if [[ $# -ne 4 ]]; then
    printf 'Usage: %s <path> <registry> <imagename> <cache>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
INPUT_REGISTRY="$2"
INPUT_IMAGENAME="$3"
INPUT_CACHE="$4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reject any cache value outside the enabled|disabled|isolated|read-only
# allowlist. This is load-bearing for SLSA L3: the reusable workflow passes
# cache=disabled for release builds, and a typo there must fail the build
# loudly rather than silently leave the BuildKit cache on (which would
# downgrade the release build from Build L3 to Build L2). The same
# allowlist constrains the value before resolve_cache.sh maps it to the
# BuildKit cache flags. See docs/SLSA_L3_AUDIT.md Finding 2 and its
# "Should wrangle care about PR-to-PR cache poisoning?" section.
if [[ ! "$INPUT_CACHE" =~ ^(enabled|disabled|isolated|read-only)$ ]]; then
    printf 'Error: invalid cache value: %s (expected enabled, disabled, isolated, or read-only)\n' "$INPUT_CACHE" >&2
    exit 1
fi

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
