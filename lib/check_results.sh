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
# Exit codes:
#   0  No findings from fail-policy tools
#   1  At least one fail-policy tool reported findings or produced invalid SARIF

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

    sarif="${METADATA_DIR}/${tool}/output.sarif"

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
