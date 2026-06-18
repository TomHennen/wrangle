#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles path arguments
# lib/write_attest_manifest.sh — write the manifest.json a producer leaves for
# the wrangle-attest engine to discover, next to its native result file.
#
# The manifest is the tool↔engine contract: predicate-type implies the result
# format, result-file is relative to the manifest's own dir. Tools never set
# subjects — the engine owns those.
#
# Usage: write_attest_manifest.sh <metadata_dir> <predicate-type> <result-file>
#   <metadata_dir>   dir holding the result file; the manifest is written here
#   <predicate-type> the in-toto predicate type URI
#   <result-file>    result filename, relative to <metadata_dir>
#
# tool/result fields (only the wrangle scan/v1 predicate needs them) are added
# by the scan adapters, not this helper — SBOM/OSV/scorecard are passthrough.

main() {
    if [[ "$#" -ne 3 ]]; then
        printf 'Usage: %s <metadata_dir> <predicate-type> <result-file>\n' "${0##*/}" >&2
        return 2
    fi
    local metadata_dir="$1" predicate_type="$2" result_file="$3"
    mkdir -p "$metadata_dir"
    # jq -n builds the JSON so a result-file or URI with a quote/backslash is
    # escaped, never breaking the manifest the engine parses strictly.
    jq -n \
        --arg pt "$predicate_type" \
        --arg rf "$result_file" \
        '{"predicate-type": $pt, "result-file": $rf}' \
        > "$metadata_dir/manifest.json"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
