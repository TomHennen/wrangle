#!/bin/bash
set -euo pipefail
set -f  # disable globbing — adapter processes external input paths

# zizmor adapter for wrangle.
# Runs the zizmor workflow security linter on source code and produces SARIF.
#
# zizmor exits 0 in SARIF mode regardless of findings (they live in the SARIF
# document), so the findings/no-findings split is derived from the SARIF result
# count, not the process exit code.
#
# Usage: adapter.sh <src_dir> <output_dir>
# Exit: 0 = no findings, 1 = findings found, 2 = tool error

if [[ $# -ne 2 ]]; then
    printf 'Usage: adapter.sh <src_dir> <output_dir>\n' >&2
    exit 2
fi

SRC_DIR="$1"
OUTPUT_DIR="$2"

if [[ ! -d "$SRC_DIR" ]]; then
    printf 'wrangle/zizmor: source directory does not exist: %s\n' "$SRC_DIR" >&2
    exit 2
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    printf 'wrangle/zizmor: output directory does not exist: %s\n' "$OUTPUT_DIR" >&2
    exit 2
fi

SARIF_FILE="${OUTPUT_DIR}/output.sarif"

# zizmor reads GITHUB_TOKEN/GH_TOKEN from the environment and enters online mode
# natively; run.sh injects the catalog secret github-token as GITHUB_TOKEN.
# Absent token leaves online audits skipped — still a valid (offline) run.
#
# SARIF goes to stdout, redirected to the file; zizmor's diagnostics stay on
# stderr (the run log). In SARIF mode zizmor exits 0 whether or not it found
# anything — the findings/no-findings split is the SARIF result count below.
zizmor_exit=0
zizmor --format sarif "$SRC_DIR" > "$SARIF_FILE" || zizmor_exit=$?

# Exit 3 = "no inputs collected" (no workflows/actions/Dependabot config in the
# tree) — a clean scan, not an error. zizmor writes nothing, so synthesize an
# empty SARIF.
if [[ "$zizmor_exit" -eq 3 ]]; then
    jq -n '{
        "version": "2.1.0",
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "runs": [{"tool": {"driver": {"name": "zizmor"}}, "results": []}]
    }' > "$SARIF_FILE"
    zizmor_exit=0
elif [[ "$zizmor_exit" -ne 0 ]]; then
    printf 'wrangle/zizmor: zizmor exited with unexpected code %d\n' "$zizmor_exit" >&2
    exit 2
fi

if ! jq empty "$SARIF_FILE" 2>/dev/null; then
    printf 'wrangle/zizmor: produced invalid JSON in SARIF output\n' >&2
    exit 2
fi

# Valid JSON isn't enough: an empty document parses but isn't SARIF. Require the
# runs array so a silent empty output can't pass as a clean scan.
if ! jq -e 'has("runs") and (.runs | type == "array")' "$SARIF_FILE" >/dev/null 2>&1; then
    printf 'wrangle/zizmor: SARIF output missing runs array\n' >&2
    exit 2
fi

if ! num_findings="$(jq '[.runs[]?.results[]?] | length' "$SARIF_FILE" 2>/dev/null)"; then
    printf 'wrangle/zizmor: failed to parse SARIF results\n' >&2
    exit 2
fi
if [[ "$num_findings" -gt 0 ]]; then
    exit 1
fi

exit 0
