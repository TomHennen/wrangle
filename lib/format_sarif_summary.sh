#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input paths

# lib/format_sarif_summary.sh — Generate sanitized markdown summary from SARIF.
# Sourced or executed directly.
#
# Usage: format_sarif_summary.sh <metadata_dir>
# Output: Markdown summary to stdout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=sanitize.sh
source "$SCRIPT_DIR/sanitize.sh"

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

    # The `error` marker takes precedence over the SARIF count: action-pattern
    # wrappers synthesise an empty fallback SARIF on tool error, so without
    # this branch the summary row would render "No findings" while the run
    # itself failed via lib/check_results.sh — misleading on the surface
    # docs/SPEC.md calls the primary output.
    if [[ -f "${dir}/error" ]]; then
        safe_tool="$(printf '%s' "$tool" | wrangle_sanitize_output)"
        printf '| %s | Tool error | [Details](#%s-details) |\n' "$safe_tool" "$safe_tool"
        continue
    fi

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

    # If the tool errored, surface the marker contents in the details
    # block — the marker is authoritative and the SARIF (if any) is the
    # synthesised empty fallback.
    if [[ -f "${dir}/error" ]]; then
        printf '## %s Details\n' "$safe_tool"
        printf '\nTool error — wrangle treated this run as fail-closed.\n\n```\n'
        wrangle_sanitize_output < "${dir}/error"
        printf '\n```\n'
        continue
    fi

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
    elif [[ -f "${dir}/output.sarif" ]]; then
        # Fallback: no tool-supplied human-readable output, but we have
        # SARIF. Render a findings table directly so adopters can see
        # WHAT was found in the step summary (issue #158) without
        # opening the raw SARIF artifact. sarif_to_md.sh exits 2 on
        # parse failure (already flagged "Error (invalid SARIF)" above)
        # and prints the literal "No findings." string on zero findings;
        # skip both cases — the top table already covers them and an
        # empty "## <tool> Details" section is just noise.
        # Truncation budget: bounded by wrangle_sanitize_output inside
        # sarif_to_md.sh ($WRANGLE_MAX_SUMMARY, 64 KB default). See
        # docs/SPEC.md §Shared Tool Helpers.
        if md_table="$("$SCRIPT_DIR/sarif_to_md.sh" "${dir}/output.sarif" 2>/dev/null)" \
            && [[ "$md_table" != "No findings." ]]; then
            printf '## %s Details\n' "$safe_tool"
            # sarif_to_md.sh already sanitizes its output; pass through.
            printf '%s\n' "$md_table"
            printf '\n'
        fi
    fi
done < <(find "$METADATA_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
