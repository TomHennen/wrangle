#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input paths

# lib/log_findings.sh — Print one-line CI log summaries per finding.
#
# Usage: log_findings.sh <metadata_dir>
#
# For each tool/output.sarif under <metadata_dir>, emits one line per
# finding to stdout in the form:
#
#   wrangle: <tool>[<i>/<n>] <ruleId> <uri>:<line> -- <message>
#
# This is informational output for CI logs so adopters (and AI agents)
# can see WHAT was found without parsing raw SARIF. It is decoupled
# from check_results.sh (which gates pass/fail) — this script always
# exits 0 and never affects the build outcome.
#
# Finding fields are sanitized:
#   - ruleId, uri, and message have \r\n\t collapsed to spaces so a
#     single finding stays on a single log line (line is numeric).
#   - HTML tags are stripped via lib/sanitize.sh.
#   - Messages are truncated to MAX_FINDING_MESSAGE bytes (default 100).
#     Note: head -c is byte-based, not char-based, matching
#     wrangle_sanitize_output's own truncation. A UTF-8 multibyte
#     sequence at the boundary may render as a replacement char.
#
# Exit codes:
#   0  Success (including malformed SARIF — skipped silently so this
#      script does not double-report against check_results.sh, which
#      is the pass/fail gate)
#   2  Usage error (missing/extra args)
#
# Malformed SARIF is silently skipped — check_results.sh is the place
# that fails on invalid SARIF; this script is purely informational.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=sanitize.sh
source "$SCRIPT_DIR/sanitize.sh"

# Maximum characters for a per-finding message in the log line.
MAX_FINDING_MESSAGE="${WRANGLE_MAX_FINDING_MESSAGE:-100}"

if [[ $# -ne 1 ]]; then
    printf 'Usage: log_findings.sh <metadata_dir>\n' >&2
    # Exit 2 for usage error to match sibling lib/ scripts
    # (sarif_to_md.sh, check_results.sh).
    exit 2
fi

METADATA_DIR="$1"

if [[ ! -d "$METADATA_DIR" ]]; then
    # Not an error — adapters may not have produced any output (e.g.,
    # all tools were skipped). Stay silent so this can be called
    # unconditionally from action.yml.
    exit 0
fi

# Iterate tools deterministically by sorting the tool directories.
while IFS= read -r -d '' dir; do
    tool="$(basename "$dir")"
    sarif="${dir}/output.sarif"

    [[ -f "$sarif" ]] || continue

    # Extract findings as TSV: ruleId<TAB>uri<TAB>line<TAB>message.
    # Skip silently on parse errors — check_results.sh is the gate.
    # Apply gsub("[\r\n\t]"; " ") to every string field (not just
    # message) so each finding renders as one CI log line regardless
    # of which attacker-controllable field contains a control char.
    # We always read .locations[0] (the primary location per SARIF
    # spec); a single result with multiple locations stays one log line.
    if ! findings="$(jq -r '
      .runs[].results[] |
        [
          ((.ruleId // "unknown-rule") | gsub("[\r\n\t]"; " ")),
          ((.locations[0].physicalLocation.artifactLocation.uri // "unknown") | gsub("[\r\n\t]"; " ")),
          ((.locations[0].physicalLocation.region.startLine // "?") | tostring),
          ((.message.text // "") | gsub("[\r\n\t]"; " "))
        ] | @tsv
    ' "$sarif" 2>/dev/null)"; then
        continue
    fi

    [[ -n "$findings" ]] || continue

    # Count findings. $(jq ...) stripped the trailing newline, so for
    # N findings $findings has N-1 embedded newlines. The printf '%s\n'
    # wrapper adds the final newline so `wc -l` returns N, not N-1.
    total="$(printf '%s\n' "$findings" | wc -l | tr -d ' ')"
    i=0

    # Sanitize tool name once.
    safe_tool="$(printf '%s' "$tool" | wrangle_sanitize_output)"

    # Use a here-string so the while loop runs in the current shell —
    # otherwise `i` would be lost in a subshell on each iteration.
    while IFS=$'\t' read -r rule uri line message; do
        i=$((i + 1))
        # Sanitize each field. wrangle_sanitize_output strips HTML and
        # truncates to MAX_SUMMARY_LENGTH — apply to each field rather
        # than the whole line so the message budget is independent.
        safe_rule="$(printf '%s' "$rule" | wrangle_sanitize_output)"
        safe_uri="$(printf '%s' "$uri" | wrangle_sanitize_output)"
        safe_line="$(printf '%s' "$line" | wrangle_sanitize_output)"
        safe_message="$(printf '%s' "$message" \
            | wrangle_sanitize_output \
            | head -c "$MAX_FINDING_MESSAGE")"
        printf 'wrangle: %s[%d/%d] %s %s:%s -- %s\n' \
            "$safe_tool" "$i" "$total" \
            "$safe_rule" "$safe_uri" "$safe_line" "$safe_message"
    done <<< "$findings"
done < <(find "$METADATA_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

exit 0
