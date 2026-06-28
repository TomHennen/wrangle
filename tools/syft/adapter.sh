#!/bin/bash
set -euo pipefail
set -f  # disable globbing — adapter processes external input paths

# syft SBOM adapter for wrangle (sbom kind).
# Generates an SPDX SBOM (sbom.spdx.json) for a source tree.
#
# Usage: adapter.sh <src_dir> <output_dir>
# Exit:  0 = SBOM written, 2 = tool error / invalid output (no findings state)

if [[ $# -ne 2 ]]; then
    printf 'Usage: adapter.sh <src_dir> <output_dir>\n' >&2
    exit 2
fi

SRC_DIR="$1"
OUTPUT_DIR="$2"

if [[ ! -d "$SRC_DIR" ]]; then
    printf 'wrangle/syft: source directory does not exist: %s\n' "$SRC_DIR" >&2
    exit 2
fi
if [[ ! -d "$OUTPUT_DIR" ]]; then
    printf 'wrangle/syft: output directory does not exist: %s\n' "$OUTPUT_DIR" >&2
    exit 2
fi

OUT_FILE="${OUTPUT_DIR}/sbom.spdx.json"

# syft writes the SBOM to stdout, logs to stderr; keep stderr to surface a real failure.
ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/wrangle-syft-err-XXXXXX")"
trap 'rm -f "$ERR_FILE"' EXIT

syft_exit=0
syft dir:"$SRC_DIR" -o spdx-json > "$OUT_FILE" 2> "$ERR_FILE" || syft_exit=$?
if [[ "$syft_exit" -ne 0 ]]; then
    printf 'wrangle/syft: syft exited with code %d\n' "$syft_exit" >&2
    cat "$ERR_FILE" >&2
    exit 2
fi

# A malformed (non-JSON) SBOM must fail, not silently pass (§3.3).
if ! jq empty "$OUT_FILE" 2>/dev/null; then
    printf 'wrangle/syft: produced invalid JSON in %s\n' "$OUT_FILE" >&2
    exit 2
fi

printf 'wrangle/syft: SBOM written to %s\n' "$OUT_FILE"
exit 0
