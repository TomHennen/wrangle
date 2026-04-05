#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external file paths

# lib/sarif_to_md.sh — Convert SARIF 2.1.0 to human-readable markdown.
#
# Usage: sarif_to_md.sh <sarif_file>
# Output: Markdown findings table to stdout (HTML-sanitized, truncated)
#
# For each result, extracts ruleId, level, file:line, and message text.
# Used by action-pattern tools to produce output.md for the step summary.
#
# Output is sanitized per CLAUDE.md: HTML tags stripped, truncated to
# prevent step summary flooding via shared wrangle_sanitize_output().

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=sanitize.sh
source "$SCRIPT_DIR/sanitize.sh"

if [[ $# -ne 1 ]]; then
    printf 'Usage: sarif_to_md.sh <sarif_file>\n' >&2
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

# Extract results; exit cleanly if no findings.
# Collapse newlines and escape pipe characters to avoid breaking the markdown
# table. HTML sanitization is applied to the final output via
# wrangle_sanitize_output (strips tags + truncates).
if ! results="$(jq -r '
  [.runs[].results[] |
    {
      ruleId: .ruleId,
      level: (.level // "warning"),
      uri: (.locations[0].physicalLocation.artifactLocation.uri // "unknown"),
      line: (.locations[0].physicalLocation.region.startLine // "?"),
      message: (.message.text | gsub("\n"; " ") | gsub("\\|"; "/"))
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

# Output markdown table, sanitized (HTML tags stripped, truncated)
{
printf '| Severity | Rule | Location | Message |\n'
printf '| -------- | ---- | -------- | ------- |\n'

printf '%s' "$results" | jq -r '.[] | "\(.level)\t\(.ruleId)\t\(.uri):\(.line)\t\(.message)"' | while IFS=$'\t' read -r level rule location message; do
    label="$(level_label "$level")"
    # shellcheck disable=SC2016 # backticks are literal markdown code spans, not command substitution
    printf '| %s | %s | `%s` | %s |\n' "$label" "$rule" "$location" "$message"
done
} | wrangle_sanitize_output
