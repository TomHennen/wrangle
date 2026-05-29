#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external tool output

# collect_sarif.sh — collect zizmor SARIF and disambiguate "found
# issues" from "tool error" for lib/check_results.sh.
#
# Hidden upstream constraint: zizmor-action pipes through `tee`, so
# SARIF_SRC always exists even on image-pull failure or mid-run crash
# (then empty/truncated). File presence does not imply success — we
# must inspect contents. zizmor exits 14 (→ outcome=failure) only after
# writing a complete SARIF with findings; anything else under
# outcome=failure is a tool error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/write_tool_error_marker.sh
source "$SCRIPT_DIR/../../lib/write_tool_error_marker.sh"

if [[ $# -ne 1 ]]; then
    printf 'Usage: collect_sarif.sh <metadata_dir>\n' >&2
    exit 1
fi

METADATA_DIR="$1"
mkdir -p "$METADATA_DIR"

SARIF_DST="${METADATA_DIR}/output.sarif"

: "${OUTCOME:=}"
SARIF_SRC="${SARIF_SRC:-}"

# src_count: -1 sentinel = "no usable SARIF" (missing / empty / unparseable /
# non-numeric jq output). Any non-negative value is a real finding count.
src_count=-1
if [[ -n "$SARIF_SRC" ]] && [[ -f "$SARIF_SRC" ]] && [[ -s "$SARIF_SRC" ]]; then
    if parsed_count="$(jq '[.runs[]?.results[]?] | length' "$SARIF_SRC" 2>/dev/null)"; then
        if [[ "$parsed_count" =~ ^[0-9]+$ ]]; then
            src_count="$parsed_count"
        fi
    fi
fi

# `[[ -le ]]` not `(( ))`: an arithmetic 0 exits non-zero, which under
# set -e could short-circuit a future && chain before the marker write.
if [[ "$OUTCOME" == "failure" ]] && [[ "$src_count" -le 0 ]]; then
    wrangle_write_tool_error_marker "$METADATA_DIR" \
        "upstream zizmor-action exited non-zero with no usable SARIF output (outcome=${OUTCOME})"
fi

if [[ "$src_count" -ge 0 ]]; then
    cp "$SARIF_SRC" "$SARIF_DST"
else
    # Synthesise an empty SARIF so the summary collector and Code Scanning
    # upload still have a file; the marker (if any) is the error signal.
    jq -n '{
        "version": "2.1.0",
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "runs": [{"tool": {"driver": {"name": "zizmor"}}, "results": []}]
    }' > "$SARIF_DST"
fi

exit 0
