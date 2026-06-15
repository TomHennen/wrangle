#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external tool output

# collect_sarif.sh — collect zizmor SARIF and disambiguate "found
# issues" from "tool error" for lib/check_results.sh.
#
# Hidden upstream constraint: with advanced-security: true the action
# runs zizmor in SARIF mode, where zizmor exits 0 regardless of findings
# (they live in the SARIF document). So outcome=failure is never a
# findings signal — it means the action's Code Scanning upload (its last
# step) failed, which it does on repos without code scanning (private,
# no Advanced Security), or zizmor itself errored before writing usable
# SARIF. The action also pipes through `tee`, so SARIF_SRC always exists
# even on image-pull failure or mid-run crash (then empty/truncated) —
# file presence does not imply success, so we inspect contents. A
# complete, parseable SARIF means the audit ran to completion and its
# result count is authoritative (>0 findings, 0 clean); only a missing,
# empty, or unparseable SARIF under outcome=failure is a tool error.

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

# Only a genuinely unusable SARIF (src_count<0) is a tool error: a
# parseable SARIF — even with zero results — means the audit finished,
# so a failed outcome over it is the upload (unavailable without
# Advanced Security), which must not fail the scan. Use `[[ -lt ]]`, not
# `(( ))`: a `(( 0 ))` test exits non-zero, which under set -e could
# short-circuit a later && chain before the marker write.
if [[ "$OUTCOME" == "failure" ]] && [[ "$src_count" -lt 0 ]]; then
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
