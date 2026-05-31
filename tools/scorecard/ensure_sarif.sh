#!/bin/bash
set -euo pipefail
set -f

# Ensure a Scorecard SARIF file exists at <sarif_file>.
#
# Scorecard commonly produces no output — it needs a GITHUB_TOKEN with
# specific scopes and only fully works on default-branch pushes, so it
# fails on most PR events. Downstream summary/collector steps need a
# well-formed SARIF to consume; when Scorecard wrote none, this emits a
# valid empty SARIF 2.1.0 so those steps don't fail.
#
# Usage: ensure_sarif.sh <sarif_file>

if [[ $# -ne 1 ]]; then
    printf 'Usage: ensure_sarif.sh <sarif_file>\n' >&2
    exit 1
fi

SARIF_FILE="$1"

if [[ ! -f "$SARIF_FILE" ]]; then
    jq -n '{
        "version": "2.1.0",
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "runs": [{"tool": {"driver": {"name": "scorecard"}}, "results": []}]
    }' > "$SARIF_FILE"
fi
