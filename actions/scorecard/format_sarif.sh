#!/bin/bash
set -euo pipefail

# Format Scorecard SARIF results into a readable markdown table.
# Usage: format_sarif.sh <sarif_file>

if [[ $# -ne 1 ]]; then
    printf 'Usage: format_sarif.sh <sarif_file>\n' >&2
    exit 1
fi

SARIF_FILE="$1"

if [[ ! -f "$SARIF_FILE" ]]; then
    printf 'Error: SARIF file not found: %s\n' "$SARIF_FILE" >&2
    exit 1
fi

printf 'Rule Name | Location | Message\n'
printf '--------- | -------- | -------\n'
jq -r '[.runs[].results[] | {rule: .ruleId, message: .message.text, locations: .locations[].physicalLocation.artifactLocation.uri}] | .[] | "\(.rule) | \(.locations) | \(.message)"' "$SARIF_FILE"
