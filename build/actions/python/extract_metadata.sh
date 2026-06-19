#!/bin/bash
set -euo pipefail
set -f

# Extract Python package metadata for the build composite: a filesystem-
# safe shortname, the per-package metadata directory, and the wheel
# name + version. Writes `shortname`, `metadata-dir`, `name`, and `version`
# to $GITHUB_OUTPUT for downstream steps.
#
# Usage: extract_metadata.sh <input_path>

if [[ $# -ne 1 ]]; then
    printf 'Usage: extract_metadata.sh <input_path>\n' >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shortname.sh
source "$SCRIPT_DIR/../../../lib/shortname.sh"

# input_path is the action's inputs.path, already constrained by
# validate_inputs.sh (lib/validate_path.sh) — the composite's first step,
# which runs before this one; no untrusted value reaches the cd / glob below.
INPUT_PATH="$1"
SHORTNAME="$(derive_shortname "$INPUT_PATH")"
METADATA_DIR="$(metadata_dir python "$SHORTNAME")"
mkdir -p "$METADATA_DIR"
printf 'shortname=%s\n' "$SHORTNAME" >> "$GITHUB_OUTPUT"
printf 'metadata-dir=%s\n' "$METADATA_DIR" >> "$GITHUB_OUTPUT"

# Read the built wheel's basename. The glob runs in a subshell so `set +f`
# cannot leak glob-enabled state to the rest of the script (a bare toggle
# would not restore under set -e); nullglob makes the no-wheel case expand
# to nothing rather than the literal pattern.
WHEEL="$(
    set +f
    shopt -s nullglob
    cd "$INPUT_PATH"
    wheels=(dist/*.whl)
    (( ${#wheels[@]} > 0 )) && basename "${wheels[0]}"
)"

# Wheel name format: {name}-{version}-{tags}.whl (PEP 427: the name segment
# is pre-escaped to [A-Za-z0-9_]+, so it has no '-' inside it).
if [[ -n "$WHEEL" ]]; then
    NAME="$(printf '%s' "$WHEEL" | sed 's/^\([^-]*\)-.*/\1/')"
    VERSION="$(printf '%s' "$WHEEL" | sed 's/^[^-]*-\([^-]*\)-.*/\1/')"
    printf 'name=%s\n' "$NAME" >> "$GITHUB_OUTPUT"
    printf 'version=%s\n' "$VERSION" >> "$GITHUB_OUTPUT"
    printf 'Package: %s %s\n' "$NAME" "$VERSION"
else
    printf 'Warning: no wheel found in dist/\n'
    printf 'name=unknown\n' >> "$GITHUB_OUTPUT"
    printf 'version=unknown\n' >> "$GITHUB_OUTPUT"
fi
