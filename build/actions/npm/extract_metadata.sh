#!/bin/bash
set -euo pipefail
set -f

# Extract npm package metadata for the build composite: a filesystem-safe
# shortname, the per-package metadata directory, and the package version.
# Writes `shortname`, `metadata-dir`, and `version` to $GITHUB_OUTPUT.
#
# Usage: extract_metadata.sh <input_path>

if [[ $# -ne 1 ]]; then
    printf 'Usage: extract_metadata.sh <input_path>\n' >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shortname.sh
source "$SCRIPT_DIR/../../../lib/shortname.sh"

# input_path is the action's inputs.path, already validated upstream.
INPUT_PATH="$1"
SHORTNAME="$(derive_shortname "$INPUT_PATH")"
METADATA_DIR="$(metadata_dir npm "$SHORTNAME")"
mkdir -p "$METADATA_DIR"
printf 'shortname=%s\n' "$SHORTNAME" >> "$GITHUB_OUTPUT"
printf 'metadata-dir=%s\n' "$METADATA_DIR" >> "$GITHUB_OUTPUT"

VERSION="$(jq -r .version "$INPUT_PATH/package.json")"
printf 'version=%s\n' "$VERSION" >> "$GITHUB_OUTPUT"
printf 'Package version: %s\n' "$VERSION"
