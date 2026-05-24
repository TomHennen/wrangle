#!/bin/bash
# Generates an SPDX SBOM for a project source tree via syft.
#
# Used by build-type composites (Go today; python/npm/container can
# migrate from their inline syft invocations in a follow-up). The
# caller is expected to have already installed syft via
# tools/syft/install.sh (Cosign-keyless-verified).
#
# Output goes to <output_path>. The composite picks a path matching
# the unified-metadata convention (e.g., metadata/go/<shortname>/sbom.spdx.json).
#
# Usage: tools/syft/generate_sbom.sh <source_dir> <output_path>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <source_dir> <output_path>\n' "$0" >&2
    exit 1
fi

SOURCE_DIR="$1"
OUTPUT_PATH="$2"

BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"
SYFT="$BIN_DIR/syft"

if [[ ! -x "$SYFT" ]]; then
    printf 'Error: syft not found at %s\n' "$SYFT" >&2
    printf 'Hint: run tools/syft/install.sh first.\n' >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
"$SYFT" dir:"$SOURCE_DIR" -o spdx-json > "$OUTPUT_PATH"
printf 'SBOM written to %s\n' "$OUTPUT_PATH"
