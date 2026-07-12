#!/bin/bash
set -euo pipefail
set -f

# lib/sarif_adapter_exit.sh — shared SARIF validation + adapter exit mapping
# (SPEC.md §Adapter Script Interface: 0 = no findings, 1 = findings, 2 = error).
#
# Usage: source this file, then end the adapter with
#   wrangle_sarif_adapter_exit <tool> <sarif_file> [clean_exit]
#
# Call it as the adapter's last statement, never in a command substitution:
# an `exit 2` inside `$(...)` only leaves the subshell, turning a malformed
# SARIF into a silent success.

# clean_exit is the status used when the SARIF holds no results (default 0);
# an adapter passes its tool's exit code to keep a findings signal the SARIF
# does not reflect.
wrangle_sarif_adapter_exit() {
    local tool="$1"
    local sarif="$2"
    local clean_exit="${3:-0}"
    local num_findings

    if [[ ! "$clean_exit" =~ ^[01]$ ]]; then
        printf '%s: clean exit status must be 0 or 1, got: %s\n' "$tool" "$clean_exit" >&2
        exit 2
    fi

    if ! jq empty "$sarif" 2>/dev/null; then
        printf '%s: produced invalid JSON in SARIF output\n' "$tool" >&2
        exit 2
    fi

    # jq reports success for a concatenated JSON stream whose last document is
    # sound, so the checks below are only trustworthy on a single document.
    if ! jq -s -e 'length == 1' "$sarif" >/dev/null 2>&1; then
        printf '%s: SARIF output is not a single JSON document\n' "$tool" >&2
        exit 2
    fi

    # Valid JSON isn't enough: an empty document parses but isn't SARIF.
    if ! jq -e 'has("runs") and (.runs | type == "array")' "$sarif" >/dev/null 2>&1; then
        printf '%s: SARIF output missing runs array\n' "$tool" >&2
        exit 2
    fi

    # A run may omit results, but any other type under that key is malformed.
    local count_results='[.runs[]
        | if type != "object" then error("run is not an object") else . end
        | if has("results") then .results else [] end
        | if type == "array" then .[] else error("results is not an array") end
        ] | length'
    if ! num_findings="$(jq "$count_results" "$sarif" 2>/dev/null)"; then
        printf '%s: failed to parse SARIF results\n' "$tool" >&2
        exit 2
    fi

    if [[ "$num_findings" -gt 0 ]]; then
        exit 1
    fi

    exit "$clean_exit"
}
