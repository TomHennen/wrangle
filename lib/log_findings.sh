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
# Finding fields are sanitized inside jq (one pass per SARIF file) so
# we don't fork 4-5 subprocesses per finding on large reports:
#   - ruleId, uri, and message have \r\n\t collapsed to spaces so a
#     single finding stays on one log line (line is numeric).
#   - HTML tags are stripped via gsub (same regex as lib/sanitize.sh).
#   - Messages are truncated to MAX_FINDING_MESSAGE characters
#     (default 100). jq slicing is char-based, not byte-based, so a
#     multibyte UTF-8 sequence at the boundary stays intact (no
#     replacement char). The whole TSV stream is then piped through
#     wrangle_sanitize_output once for the global $WRANGLE_MAX_SUMMARY cap.
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

    # Extract findings as TSV: ruleId<TAB>uri<TAB>line<TAB>message, with
    # all string-field sanitization done inside jq (gsub for \r\n\t and
    # HTML tags, message truncated to MAX_FINDING_MESSAGE). Skip silently
    # on parse errors — check_results.sh is the gate.
    # We always read .locations[0] (the primary location per SARIF
    # spec); a single result with multiple locations stays one log line.
    if ! findings="$(jq -r --argjson maxmsg "$MAX_FINDING_MESSAGE" '
      def clean: gsub("[\r\n\t]"; " ") | gsub("<[^>]*>"; "");
      .runs[].results[] |
        [
          ((.ruleId // "unknown-rule") | clean),
          ((.locations[0].physicalLocation.artifactLocation.uri // "unknown") | clean),
          ((.locations[0].physicalLocation.region.startLine // "?") | tostring),
          ((.message.text // "") | clean | .[0:$maxmsg])
        ] | @tsv
    ' "$sarif" 2>/dev/null \
        | wrangle_sanitize_output)"; then
        continue
    fi

    [[ -n "$findings" ]] || continue

    # Count findings. $(jq ...) stripped the trailing newline, so for
    # N findings $findings has N-1 embedded newlines. The printf '%s\n'
    # wrapper adds the final newline so `wc -l` returns N, not N-1.
    total="$(printf '%s\n' "$findings" | wc -l | tr -d ' ')"
    i=0

    # Sanitize tool name once (jq didn't see it — it comes from the
    # directory name, not the SARIF).
    safe_tool="$(printf '%s' "$tool" | wrangle_sanitize_output)"

    # Use a here-string so the while loop runs in the current shell —
    # otherwise `i` would be lost in a subshell on each iteration.
    # Fields are already sanitized inside jq, so no per-field forking.
    while IFS=$'\t' read -r rule uri line message; do
        i=$((i + 1))
        printf 'wrangle: %s[%d/%d] %s %s:%s -- %s\n' \
            "$safe_tool" "$i" "$total" \
            "$rule" "$uri" "$line" "$message"
    done <<< "$findings"
done < <(find "$METADATA_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

exit 0
