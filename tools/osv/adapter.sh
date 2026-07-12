#!/bin/bash
set -euo pipefail
set -f  # disable globbing — adapter processes external input paths

# OSV-Scanner adapter for wrangle.
# Runs OSV-Scanner on source code and produces SARIF output.
#
# Usage: adapter.sh <src_dir> <output_dir>
# Exit: 0 = no findings, 1 = findings found, 2 = tool error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/sarif_adapter_exit.sh
source "$SCRIPT_DIR/../../lib/sarif_adapter_exit.sh"

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

# Generate markdown summary from the SARIF we just produced. Using a local
# render_md.sh (rather than a second osv-scanner invocation with
# --format markdown) guarantees the summary and the SARIF-based check report
# the same findings — osv-scanner's markdown formatter has been observed
# reporting zero findings while the SARIF contains results (issue #197).
# Best-effort: a failure here loses the summary but must not fail the
# scan, since the SARIF (which the gating check consults) is already written.
"$SCRIPT_DIR/render_md.sh" "$SARIF_FILE" > "$MD_FILE" 2>/dev/null || \
    printf 'wrangle/osv: failed to render markdown summary (SARIF still valid)\n' > "$MD_FILE"

# osv_exit as the no-findings status: osv-scanner signalling vulnerabilities the
# SARIF does not carry must not report a clean scan.
wrangle_sarif_adapter_exit 'wrangle/osv' "$SARIF_FILE" "$osv_exit"
