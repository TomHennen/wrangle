#!/bin/bash
set -euo pipefail

# lib/sarif_to_text.sh — Convert SARIF 2.1.0 to human-readable text.
#
# Usage: sarif_to_text.sh <sarif_file>
# Output: Plain text findings to stdout
#
# For each result, extracts ruleId, level, file:line, and message text.
# Used by action-pattern tools to produce output.txt for the step summary.

if [[ $# -ne 1 ]]; then
    printf 'Usage: sarif_to_text.sh <sarif_file>\n' >&2
    exit 1
fi

SARIF_FILE="$1"

if [[ ! -f "$SARIF_FILE" ]]; then
    printf 'Error: SARIF file not found: %s\n' "$SARIF_FILE" >&2
    exit 1
fi

# Validate SARIF is valid JSON
if ! jq empty "$SARIF_FILE" 2>/dev/null; then
    printf 'Error: invalid JSON in SARIF file: %s\n' "$SARIF_FILE" >&2
    exit 2
fi

# Extract results; exit cleanly if no findings
if ! results="$(jq -r '
  [.runs[].results[] |
    {
      ruleId: .ruleId,
      level: (.level // "warning"),
      uri: (.locations[0].physicalLocation.artifactLocation.uri // "unknown"),
      line: (.locations[0].physicalLocation.region.startLine // "?"),
      message: .message.text
    }
  ]' "$SARIF_FILE" 2>/dev/null)"; then
    printf 'Error: failed to parse SARIF results\n' >&2
    exit 2
fi

count="$(printf '%s' "$results" | jq 'length')"
if [[ "$count" -eq 0 ]]; then
    printf 'No findings.\n'
    exit 0
fi

# Map SARIF levels to display labels
level_label() {
    case "$1" in
        error)   printf 'HIGH' ;;
        warning) printf 'MED' ;;
        note)    printf 'LOW' ;;
        *)       printf '%s' "$1" ;;
    esac
}

# Output each finding
printf '%s' "$results" | jq -r '.[] | "\(.level)\t\(.ruleId)\t\(.uri):\(.line)\t\(.message)"' | while IFS=$'\t' read -r level rule location message; do
    label="$(level_label "$level")"
    printf '[%s] %s — %s\n' "$label" "$rule" "$location"
    printf '  %s\n\n' "$message"
done
