#!/bin/bash
# Verifies wrangle-generated SLSA provenance against a goreleaser-
# produced dist directory.
#
# The subject filename list is read from dist/checksums.txt rather
# than globbed from the directory. Globbing would include goreleaser-
# internal metadata files (artifacts.json, config.yaml, metadata.json)
# that aren't subjects, causing slsa-verifier to fail with "artifact
# hash does not match provenance subject." checksums.txt is the
# authoritative subject list — slsa-verifier re-hashes each file and
# compares against the provenance.
#
# Usage: verify_provenance.sh <dist_dir> <provenance_path> <source_uri>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

# Pure function: parse dist/checksums.txt and print one artifact path
# per line (prefixed with dist_dir/). Each line in checksums.txt is
# `<sha256>  <filename>` (two-space separator per sha256sum's default);
# awk drops the first whitespace-delimited field, strips the leading
# spaces, and prefixes with dist/.
#
# Args: <dist_dir> <checksums_path>
list_artifacts() {
    local dist_dir="$1"
    local checksums="$2"
    if [[ ! -f "$checksums" ]]; then
        printf 'Error: checksums file not found: %s\n' "$checksums" >&2
        return 1
    fi
    # NF > 0 filters out blank lines defensively — a trailing newline
    # in checksums.txt would otherwise produce a bare "dist/" entry
    # that slsa-verifier would treat as a filename and fail confusingly.
    awk -v d="$dist_dir/" 'NF > 0 { $1=""; sub(/^ +/, ""); print d $0 }' "$checksums"
}

main() {
    if [[ $# -ne 3 ]]; then
        printf 'Usage: %s <dist_dir> <provenance_path> <source_uri>\n' "$0" >&2
        exit 1
    fi

    local dist_dir="$1"
    local provenance="$2"
    local source_uri="$3"

    # Pre-check explicitly so the actual error from list_artifacts
    # (e.g., "checksums file not found") propagates. mapfile's
    # process substitution swallows non-zero exit codes from the
    # producer, so a missing checksums file would otherwise surface
    # below as the less-helpful "checksums.txt is empty."
    local checksums="$dist_dir/checksums.txt"
    if [[ ! -f "$checksums" ]]; then
        printf 'Error: checksums file not found: %s\n' "$checksums" >&2
        exit 1
    fi

    mapfile -t artifacts < <(list_artifacts "$dist_dir" "$checksums")
    if (( ${#artifacts[@]} == 0 )); then
        printf 'Error: %s contains no artifact entries; nothing to verify\n' "$checksums" >&2
        exit 1
    fi

    slsa-verifier verify-artifact \
        --provenance-path "$provenance" \
        --source-uri "$source_uri" \
        "${artifacts[@]}"
}

# Sourcing guard: tests source this file to call list_artifacts()
# directly without invoking slsa-verifier.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
