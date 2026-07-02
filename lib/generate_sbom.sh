#!/bin/bash
set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

# lib/generate_sbom.sh — generate an SPDX SBOM for a build-type source tree by
# dispatching a curated SBOM tool (default: syft) through the orchestrator.
#
# Usage: generate_sbom.sh <src_dir> <metadata_dir> [<tool>]

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'Usage: %s <src_dir> <metadata_dir> [<tool>]\n' "${0##*/}" >&2
    exit 2
fi

SRC_DIR="$1"
METADATA_DIR="$2"
TOOL="${3:-syft}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRANGLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$METADATA_DIR"

"$WRANGLE_ROOT/run.sh" -s "$SRC_DIR" -o "$METADATA_DIR" "$TOOL"

TOOL_OUT="${METADATA_DIR}/${TOOL}"
if [[ ! -f "${TOOL_OUT}/sbom.spdx.json" ]]; then
    printf 'wrangle: SBOM not produced at %s\n' "${TOOL_OUT}/sbom.spdx.json" >&2
    exit 2
fi

# The attest engine only discovers a manifest at the metadata-dir root, so lift
# run.sh's <tool>/ outputs up out of the per-tool subdir.
( set +f; mv "${TOOL_OUT}"/* "${METADATA_DIR}/" )
rmdir "$TOOL_OUT"
