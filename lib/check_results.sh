#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input

# lib/check_results.sh — Check scan results against tool policies.
#
# Usage: check_results.sh <metadata_dir> <tool[:policy]> [tool[:policy]] ...
#
# Each tool has a :fail (default) or :info policy. :fail blocks the exit
# on findings, :info logs them. The exit is non-zero if any :fail tool
# reported findings, errored, or produced invalid SARIF.
#
# Error-marker contract: <metadata_dir>/<tool>/error, if present, signals
# the upstream tool failed (API down, network failure) — distinct from
# "ran and found nothing". It takes precedence over the SARIF count so a
# wrapper-synthesised empty fallback SARIF can't mask a tool error.
# Contents are treated as untrusted — sanitised before logging — so
# wrappers may interpolate upstream output without re-sanitising.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sanitize.sh
source "$SCRIPT_DIR/sanitize.sh"

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

    if [[ -f "$error_marker" ]]; then
        # First line only, sanitised — wrapper-supplied marker text is
        # untrusted (see header) and reaches the GitHub Actions log here.
        err_msg="$(head -n1 -- "$error_marker" 2>/dev/null | wrangle_sanitize_output || true)"
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
        manifest="${METADATA_DIR}/${tool}/wrangle_attestation_metadata.json"
        if [[ "$policy" == "fail" && -f "$manifest" ]]; then
            result_file="$(jq -r '."result-file" // empty' "$manifest" 2>/dev/null || true)"
            if [[ -n "$result_file" && -f "${METADATA_DIR}/${tool}/${result_file}" ]]; then
                # A passthrough tool ran (manifest + result present) but emits no
                # SARIF, so :fail can never block. Warn rather than fail-open.
                printf 'wrangle: %s:fail has no effect without SARIF findings — score-based gating tracked in #497\n' "$tool" >&2
            fi
        fi
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
