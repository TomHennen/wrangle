#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input paths

# lib/format_sarif_summary.sh — Generate sanitized markdown summary from SARIF.
# Sourced or executed directly.
#
# Usage: format_sarif_summary.sh <metadata_dir>
# Output: Markdown summary to stdout

# Maximum characters for step summary (prevent flooding)
MAX_SUMMARY_LENGTH="${WRANGLE_MAX_SUMMARY:-65536}"

# Strip HTML tags from input to prevent markdown/HTML injection.
# Uses printf '%s' for untrusted content per CLAUDE.md.
wrangle_sanitize_output() {
    # Remove HTML tags, then truncate
    sed 's/<[^>]*>//g' | head -c "$MAX_SUMMARY_LENGTH"
}

# Main
if [[ $# -ne 1 ]]; then
    printf 'Usage: format_sarif_summary.sh <metadata_dir>\n' >&2
    exit 1
fi

METADATA_DIR="$1"

if [[ ! -d "$METADATA_DIR" ]]; then
    printf 'Error: metadata directory does not exist: %s\n' "$METADATA_DIR" >&2
    exit 1
fi

# Summary table header
printf '# Wrangle results\n'
printf '| Tool | Status | Results |\n'
printf '| ---- | ------ | ------- |\n'

while IFS= read -r -d '' dir; do
    tool="$(basename "$dir")"

    if [[ -f "${dir}/output.sarif" ]]; then
        tool_status="No findings"

        # Check jq exit code per spec
        if ! num_findings="$(jq '[.runs[].results[]] | length' "${dir}/output.sarif" 2>/dev/null)"; then
            tool_status="Error (invalid SARIF)"
        elif [[ "$num_findings" -gt 0 ]]; then
            tool_status="${num_findings} findings"
        fi

        # Sanitize tool name before embedding in markdown
        safe_tool="$(printf '%s' "$tool" | wrangle_sanitize_output)"
        printf '| %s | %s | [Details](#%s-details) |\n' "$safe_tool" "$tool_status" "$safe_tool"
    fi
done < <(find "$METADATA_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

printf '\n'

# Tool details
while IFS= read -r -d '' dir; do
    tool="$(basename "$dir")"
    safe_tool="$(printf '%s' "$tool" | wrangle_sanitize_output)"

    if [[ -f "${dir}/output.txt" ]]; then
        printf '## %s Details\n' "$safe_tool"
        printf '\n```\n'
        # Sanitize tool output: strip HTML tags, truncate
        wrangle_sanitize_output < "${dir}/output.txt"
        printf '\n```\n'
    elif [[ -f "${dir}/output.md" ]]; then
        printf '## %s Details\n' "$safe_tool"
        # Sanitize markdown output: strip HTML tags, truncate
        wrangle_sanitize_output < "${dir}/output.md"
        printf '\n'
    fi
done < <(find "$METADATA_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
