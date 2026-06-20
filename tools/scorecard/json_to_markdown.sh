#!/bin/bash
set -euo pipefail
set -f

# Render a Scorecard JSON result (scorecard --format=json) into a readable
# markdown summary: the aggregate score plus a per-check table.
#
# Usage: json_to_markdown.sh <json_file>

if [[ $# -ne 1 ]]; then
    printf 'Usage: json_to_markdown.sh <json_file>\n' >&2
    exit 1
fi

JSON_FILE="$1"

if [[ ! -f "$JSON_FILE" ]]; then
    printf 'Error: JSON file not found: %s\n' "$JSON_FILE" >&2
    exit 1
fi

if ! jq empty "$JSON_FILE" 2>/dev/null; then
    printf 'Error: invalid JSON in file: %s\n' "$JSON_FILE" >&2
    exit 2
fi

MAX_OUTPUT="${WRANGLE_MAX_SUMMARY:-65536}"

if ! score="$(jq -r '.score // "n/a"' "$JSON_FILE" 2>/dev/null)"; then
    printf 'Error: failed to parse Scorecard JSON\n' >&2
    exit 2
fi

printf 'Aggregate score: %s / 10\n\n' "$score"
printf '%s\n' 'Check | Score | Reason'
printf '%s\n' '----- | ----- | ------'

# Per-check rows; strip HTML and collapse newlines so each check stays on one row.
# Capture, then cap with a substring instead of piping into head: a pipe into
# head closes at the byte cap, SIGPIPEs the producer, and pipefail turns a valid
# truncation into a false error.
if ! checks="$(jq -r '(.checks // [])[] | "\(.name) | \(.score) | \(.reason)"' "$JSON_FILE" 2>/dev/null | sed 's/<[^>]*>//g')"; then
    printf 'Error: failed to parse Scorecard checks\n' >&2
    exit 2
fi

# Cap in a C-locale subshell so the substring is byte-indexed (matching the cap).
( export LC_ALL=C; printf '%s\n' "${checks:0:$MAX_OUTPUT}" )
