#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input

# lib/check_results.sh — Check scan results against tool policies.
#
# Usage: check_results.sh <metadata_dir> <tool[:policy]> [tool[:policy]] ...
#
# Each tool argument is a name with an optional :fail or :info suffix.
# Default policy is :fail. Tools with :fail policy cause a non-zero exit
# if they reported findings. Tools with :info policy are informational —
# findings are noted but do not affect the exit code.
#
# Tool-error semantics: when an action-pattern tool's wrapper writes an
# `error` marker file at <metadata_dir>/<tool>/error, that signals the
# underlying tool failed to run (API unavailable, network failure, etc.)
# — distinct from "tool ran and found nothing". For :fail-policy tools
# the marker causes exit 1 (fail closed). For :info-policy tools the
# marker is logged but does not affect the exit code. The marker takes
# precedence over the SARIF count to prevent a fallback empty SARIF (0
# results) from masking a tool error.
#
# Exit codes:
#   0  No findings from fail-policy tools
#   1  At least one fail-policy tool reported findings, errored, or
#      produced invalid SARIF

if [[ $# -lt 2 ]]; then
    printf 'Usage: check_results.sh <metadata_dir> <tool[:policy]> ...\n' >&2
    exit 2
fi

METADATA_DIR="$1"
shift

if [[ ! -d "$METADATA_DIR" ]]; then
    printf 'Error: metadata directory does not exist: %s\n' "$METADATA_DIR" >&2
    exit 2
fi

exit_code=0

for spec in "$@"; do
    # Parse tool:policy — default policy is "fail"
    tool="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then
        policy="${spec#*:}"
    else
        policy="fail"
    fi

    # Validate policy
    if [[ "$policy" != "fail" ]] && [[ "$policy" != "info" ]]; then
        printf 'wrangle: invalid policy for %s: %s (expected fail or info)\n' "$tool" "$policy" >&2
        exit_code=1
        continue
    fi

    error_marker="${METADATA_DIR}/${tool}/error"
    sarif="${METADATA_DIR}/${tool}/output.sarif"

    # Error marker takes precedence over SARIF counting. An action-pattern
    # tool's wrapper writes this when the upstream step exits non-zero in a
    # way that does not correspond to "found issues" (e.g., API down). For
    # :fail tools this is a hard failure; for :info tools it is logged but
    # not blocking. We do not fall through to the SARIF count — the wrapper
    # may have synthesized an empty fallback SARIF that would otherwise be
    # misread as "no findings".
    if [[ -f "$error_marker" ]]; then
        # Read the first line of the marker for context, sanitised to a
        # single line. Falls back to a generic message if read fails.
        err_msg="$(head -n1 -- "$error_marker" 2>/dev/null || true)"
        if [[ -z "$err_msg" ]]; then
            err_msg="upstream tool failed"
        fi
        if [[ "$policy" == "fail" ]]; then
            printf 'wrangle: %s errored: %s\n' "$tool" "$err_msg" >&2
            exit_code=1
        else
            printf 'wrangle: %s errored: %s (informational)\n' "$tool" "$err_msg"
        fi
        continue
    fi

    if [[ ! -f "$sarif" ]]; then
        # No SARIF means the tool didn't run or didn't produce output.
        # Not an error — the tool may have been skipped (e.g., Scorecard on PRs).
        continue
    fi

    if ! count="$(jq '[.runs[].results[]] | length' "$sarif" 2>/dev/null)"; then
        printf 'wrangle: %s produced invalid SARIF\n' "$tool" >&2
        if [[ "$policy" == "fail" ]]; then
            exit_code=1
        fi
        continue
    fi

    if [[ "$count" -gt 0 ]]; then
        if [[ "$policy" == "fail" ]]; then
            printf 'wrangle: %s reported %s finding(s)\n' "$tool" "$count"
            exit_code=1
        else
            printf 'wrangle: %s reported %s finding(s) (informational)\n' "$tool" "$count"
        fi
    fi
done

exit "$exit_code"
