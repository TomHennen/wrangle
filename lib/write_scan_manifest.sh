#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles path arguments

# lib/write_scan_manifest.sh — write the scan/v1 wrangle_attestation_metadata.json
# a SARIF-emitting tool leaves for the wrangle-attest engine, next to its
# output.sarif.
#
# This is the generic producer for the wrangle scan/v1 thin envelope: every
# SARIF tool (osv now; zizmor/scorecard/wrangle-lint in Phase 2) writes the same
# manifest, keyed only by tool name + SARIF path. tool.version and the
# clean|findings result are derived from the SARIF itself — the same results
# count the findings gate uses — so producer and gate can never diverge.
#
# Usage: write_scan_manifest.sh <tool_name> <sarif_path>
#   <tool_name>  the scanner's name (e.g. osv-scanner); recorded as tool.name
#   <sarif_path> the output.sarif; the manifest is written in its directory,
#                with result-file pointing at it

PREDICATE_SCAN_V1="https://github.com/TomHennen/wrangle/attestation/scan/v1"

main() {
    if [[ "$#" -ne 2 ]]; then
        printf 'Usage: %s <tool_name> <sarif_path>\n' "${0##*/}" >&2
        return 2
    fi
    local tool_name="$1" sarif_path="$2"
    if [[ ! -f "$sarif_path" ]]; then
        printf 'write_scan_manifest: SARIF not found: %s\n' "$sarif_path" >&2
        return 2
    fi
    local metadata_dir result_file
    metadata_dir="$(dirname "$sarif_path")"
    result_file="$(basename "$sarif_path")"

    # Action-pattern tools (zizmor, dependency-review) write an error marker
    # when the run failed and any SARIF on disk is an empty fallback. Don't
    # attest that: an attestation must claim a real scan result. (run.sh's
    # adapter path gates on tool_status and never calls here on error.)
    if [[ -f "$metadata_dir/error" ]]; then
        return 0
    fi

    # result and version come from the SARIF: results count is the same signal
    # the gate reads (clean|findings); version is the driver's reported version.
    local count result version
    if ! count="$(jq '[.runs[].results[]] | length' "$sarif_path" 2>/dev/null)"; then
        printf 'write_scan_manifest: invalid SARIF: %s\n' "$sarif_path" >&2
        return 2
    fi
    if [[ "$count" -gt 0 ]]; then
        result="findings"
    else
        result="clean"
    fi
    version="$(jq -r 'first(.runs[].tool.driver.version) // ""' "$sarif_path" 2>/dev/null || printf '')"

    # jq -n builds the JSON so a tool name or version with a quote/backslash is
    # escaped, never breaking the manifest the engine parses strictly.
    jq -n \
        --arg pt "$PREDICATE_SCAN_V1" \
        --arg rf "$result_file" \
        --arg tn "$tool_name" \
        --arg tv "$version" \
        --arg rs "$result" \
        '{"predicate-type": $pt, "result-file": $rf, "tool": {"name": $tn, "version": $tv}, "result": $rs}' \
        > "$metadata_dir/wrangle_attestation_metadata.json"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
