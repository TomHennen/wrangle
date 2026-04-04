#!/bin/bash
set -euo pipefail

# OSV-Scanner adapter for wrangle.
# Runs OSV-Scanner on source code and produces SARIF output.
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
    printf 'wrangle/osv: source directory does not exist: %s\n' "$SRC_DIR" >&2
    exit 2
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    printf 'wrangle/osv: output directory does not exist: %s\n' "$OUTPUT_DIR" >&2
    exit 2
fi

SARIF_FILE="${OUTPUT_DIR}/output.sarif"
MD_FILE="${OUTPUT_DIR}/output.md"

# Run OSV-Scanner for SARIF output
osv_exit=0
osv-scanner scan --format sarif --output "$SARIF_FILE" -r "$SRC_DIR" || osv_exit=$?

# Exit code 128 means "no package sources found" — treat as clean scan
if [[ "$osv_exit" -eq 128 ]]; then
    printf 'wrangle/osv: no package sources found, generating empty SARIF\n'
    # Generate a minimal valid SARIF with no findings
    osv_version="$(osv-scanner --version 2>/dev/null || printf 'unknown')"
    jq -n \
        --arg ver "$osv_version" \
        '{
            "version": "2.1.0",
            "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
            "runs": [{
                "tool": {"driver": {"name": "osv-scanner", "informationUri": "https://github.com/google/osv-scanner", "version": $ver}},
                "results": []
            }]
        }' > "$SARIF_FILE"
    osv_exit=0
elif [[ "$osv_exit" -ge 2 ]] && [[ "$osv_exit" -ne 1 ]]; then
    # Exit codes other than 0, 1, 128 are tool errors
    printf 'wrangle/osv: osv-scanner exited with unexpected code %d\n' "$osv_exit" >&2
    exit 2
fi

# Validate SARIF output
if ! jq empty "$SARIF_FILE" 2>/dev/null; then
    printf 'wrangle/osv: produced invalid JSON in SARIF output\n' >&2
    exit 2
fi

# Generate markdown output (best-effort, non-fatal)
osv-scanner scan --format markdown --output "$MD_FILE" -r "$SRC_DIR" 2>/dev/null || true

# Determine exit code from SARIF results
if ! num_findings="$(jq '[.runs[].results[]] | length' "$SARIF_FILE" 2>/dev/null)"; then
    printf 'wrangle/osv: failed to parse SARIF results\n' >&2
    exit 2
fi
if [[ "$num_findings" -gt 0 ]]; then
    exit 1
fi

exit "$osv_exit"
