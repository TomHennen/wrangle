#!/bin/bash
set -euo pipefail
set -f

# Extract Python package metadata for the build composite: a filesystem-
# safe shortname, the per-package metadata directory, and the wheel
# version. Writes `shortname`, `metadata-dir`, and `version` to
# $GITHUB_OUTPUT for downstream steps.
#
# Usage: extract_metadata.sh <input_path>

if [[ $# -ne 1 ]]; then
    printf 'Usage: extract_metadata.sh <input_path>\n' >&2
    exit 1
fi

# input_path is the action's inputs.path, already constrained by
# validate_inputs.sh (lib/validate_path.sh) — the composite's first step,
# which runs before this one; no untrusted value reaches the cd / glob below.
INPUT_PATH="$1"
SHORTNAME="${INPUT_PATH////_}"
METADATA_DIR="metadata/python/${SHORTNAME}"
mkdir -p "$METADATA_DIR"
printf 'shortname=%s\n' "$SHORTNAME" >> "$GITHUB_OUTPUT"
printf 'metadata-dir=%s\n' "$METADATA_DIR" >> "$GITHUB_OUTPUT"

# Extract the version from the built wheel filename. The glob runs in a
# subshell so `set +f` cannot leak glob-enabled state to the rest of the
# script (a bare toggle would not restore under set -e); nullglob makes
# the no-wheel case expand to nothing rather than the literal pattern.
# Wheel name format: {name}-{version}-{tags}.whl
VERSION="$(
    set +f
    shopt -s nullglob
    cd "$INPUT_PATH"
    wheels=(dist/*.whl)
    if (( ${#wheels[@]} > 0 )); then
        basename "${wheels[0]}" | sed 's/^[^-]*-\([^-]*\)-.*/\1/'
    fi
)"

if [[ -n "$VERSION" ]]; then
    printf 'version=%s\n' "$VERSION" >> "$GITHUB_OUTPUT"
    printf 'Package version: %s\n' "$VERSION"
else
    printf 'Warning: no wheel found in dist/\n'
    printf 'version=unknown\n' >> "$GITHUB_OUTPUT"
fi
