#!/bin/bash
set -euo pipefail

# Format Scorecard SARIF results into a readable markdown table.
#
# Scorecard is a GitHub Action (not a standalone binary), so it follows
# the "wrapped composite action" pattern instead of the adapter pattern.
# See SPEC.md "Why Scorecard is different" — Scorecard requires the
# GitHub Actions context (repository metadata, API access) which makes
# it incompatible with the adapter's environment isolation.
#
# Usage: sarif_to_markdown.sh <sarif_file>

if [[ $# -ne 1 ]]; then
    printf 'Usage: sarif_to_markdown.sh <sarif_file>\n' >&2
    exit 1
fi

SARIF_FILE="$1"

if [[ ! -f "$SARIF_FILE" ]]; then
    printf 'Error: SARIF file not found: %s\n' "$SARIF_FILE" >&2
    exit 1
fi

# Validate SARIF is valid JSON before processing
if ! jq empty "$SARIF_FILE" 2>/dev/null; then
    printf 'Error: invalid JSON in SARIF file: %s\n' "$SARIF_FILE" >&2
    exit 2
fi

printf '%s\n' 'Rule Name | Location | Message'
printf '%s\n' '--------- | -------- | -------'

# Extract results, strip HTML tags, and truncate to prevent summary flooding
MAX_OUTPUT="${WRANGLE_MAX_SUMMARY:-65536}"
if ! jq -r '[.runs[].results[] | {rule: .ruleId, message: .message.text, locations: .locations[].physicalLocation.artifactLocation.uri}] | .[] | "\(.rule) | \(.locations) | \(.message)"' "$SARIF_FILE" 2>/dev/null | sed 's/<[^>]*>//g' | head -c "$MAX_OUTPUT"; then
    printf 'Error: failed to parse SARIF results\n' >&2
    exit 2
fi
