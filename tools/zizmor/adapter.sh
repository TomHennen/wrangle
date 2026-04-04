#!/bin/bash
set -euo pipefail
set -f  # disable globbing — adapter processes external input paths

# Zizmor adapter for wrangle.
# Runs Zizmor on GitHub Actions workflow files and produces SARIF output.
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
TXT_FILE="${OUTPUT_DIR}/output.txt"
WORKFLOW_DIR="${SRC_DIR}/.github/workflows"

# If no workflow directory exists, produce empty SARIF (nothing to scan)
if [[ ! -d "$WORKFLOW_DIR" ]]; then
    printf 'wrangle/zizmor: no .github/workflows directory found, skipping\n'
    jq -n '{
        "version": "2.1.0",
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "runs": [{
            "tool": {"driver": {"name": "zizmor", "informationUri": "https://github.com/woodruffw/zizmor"}},
            "results": []
        }]
    }' > "$SARIF_FILE"
    exit 0
fi

# Collect workflow files safely (no unquoted find, no globbing issues)
# Globbing already disabled at script top via set -f
workflow_files=()
while IFS= read -r -d '' file; do
    workflow_files+=("$file")
done < <(find "$WORKFLOW_DIR" -name '*.yml' -print0 2>/dev/null)

if [[ ${#workflow_files[@]} -eq 0 ]]; then
    printf 'wrangle/zizmor: no .yml files in %s, skipping\n' "$WORKFLOW_DIR"
    jq -n '{
        "version": "2.1.0",
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "runs": [{
            "tool": {"driver": {"name": "zizmor", "informationUri": "https://github.com/woodruffw/zizmor"}},
            "results": []
        }]
    }' > "$SARIF_FILE"
    exit 0
fi

# Run Zizmor for SARIF output. We ignore zizmor's exit code because its
# exit codes for findings are unreliable — we determine findings from SARIF.
export NO_COLOR=1
zizmor --format sarif "${workflow_files[@]}" > "$SARIF_FILE" || true

# Validate SARIF output
if ! jq empty "$SARIF_FILE" 2>/dev/null; then
    printf 'wrangle/zizmor: produced invalid JSON in SARIF output\n' >&2
    exit 2
fi

# Generate plain text output (best-effort, non-fatal)
zizmor --format plain "${workflow_files[@]}" > "$TXT_FILE" 2>/dev/null || true

# Determine findings from SARIF (zizmor's exit codes for findings are unreliable
# per the old script, so check SARIF directly)
if ! num_findings="$(jq '[.runs[].results[]] | length' "$SARIF_FILE" 2>/dev/null)"; then
    printf 'wrangle/zizmor: failed to parse SARIF results\n' >&2
    exit 2
fi

# Also check for "fail" kind results (zizmor-specific)
has_failures="$(jq 'any(.runs[].results[].kind; contains("fail"))' "$SARIF_FILE" 2>/dev/null || printf 'false')"

if [[ "$num_findings" -gt 0 ]] || [[ "$has_failures" == "true" ]]; then
    exit 1
fi

exit 0
