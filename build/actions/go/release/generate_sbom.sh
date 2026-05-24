#!/bin/bash
# Generates an SPDX SBOM for the project source tree via syft.
#
# Same tool wrangle's python and npm composites use, with the same
# Cosign-keyless install via tools/syft/install.sh. The output
# matches the unified-metadata convention: <metadata_dir>/sbom.spdx.json.
#
# Why a separate script: the action.yml previously inlined the syft
# invocation, which (a) duplicated logic across python/npm/go and
# (b) wasn't testable. This script is wrangle-Go-only for now — a
# follow-up that migrates python and npm to a shared lib/generate_sbom.sh
# is tracked separately.
#
# Usage: build/actions/go/release/generate_sbom.sh <source_dir> <output_path>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <source_dir> <output_path>\n' "$0" >&2
    exit 1
fi

SOURCE_DIR="$1"
OUTPUT_PATH="$2"

# Locate the wrangle-installed syft binary. WRANGLE_BIN_DIR is set
# by the composite via setup or, when not present (tests), default
# to the standard wrangle convention.
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"
SYFT="$BIN_DIR/syft"

if [[ ! -x "$SYFT" ]]; then
    printf 'Error: syft not found at %s\n' "$SYFT" >&2
    printf 'Hint: run tools/syft/install.sh first (the composite does this in an earlier step)\n' >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
"$SYFT" dir:"$SOURCE_DIR" -o spdx-json > "$OUTPUT_PATH"
printf 'SBOM written to %s\n' "$OUTPUT_PATH"
