#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external tool output

# collect_sarif.sh — collect the zizmor SARIF into the wrangle metadata
# directory and disambiguate "found issues" from "tool error" so
# lib/check_results.sh can fail closed on real errors.
#
# Hidden upstream constraint: zizmorcore/zizmor-action pipes through
# `tee` and always exports the output-file path, so SARIF_SRC is always
# non-empty and the file always exists — even on image-pull failure or
# mid-run crash, when its contents are empty/truncated/garbled. We
# therefore can't infer success from "file present"; we must inspect it.
#
# Disambiguation: on OUTCOME == "failure", trust the SARIF only when it
# parses AND contains at least one result. zizmor exits 14 (→
# outcome=failure) only after writing a complete SARIF with findings;
# everything else (missing, empty, malformed, or zero results with
# outcome=failure) is a tool error and gets the marker. A partially-
# truncated parseable SARIF is preserved so :fail still blocks via the
# count — it may under-report, but never silently drops to zero.
#
# Inputs (env):
#   SARIF_SRC — upstream action's output-file path
#   OUTCOME   — upstream step's outcome string (success/failure/etc.)
# Args: $1 — metadata directory.
# Side effects: writes <metadata_dir>/output.sarif (real or synthesised
# empty) and <metadata_dir>/error on tool error.
# Exit: always 0 — the marker, not this script's exit code, is what
# check_results.sh consumes.

if [[ $# -ne 1 ]]; then
    printf 'Usage: collect_sarif.sh <metadata_dir>\n' >&2
    exit 1
fi

METADATA_DIR="$1"
mkdir -p "$METADATA_DIR"

SARIF_DST="${METADATA_DIR}/output.sarif"
ERROR_MARKER="${METADATA_DIR}/error"

# Default missing env so set -u doesn't trip.
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
    printf 'upstream zizmor-action exited non-zero with no usable SARIF output (outcome=%s)\n' \
        "$OUTCOME" > "$ERROR_MARKER"
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

# Always succeed: errors and findings are communicated via marker + SARIF.
exit 0
