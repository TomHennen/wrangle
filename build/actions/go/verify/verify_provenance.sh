#!/bin/bash
# Verifies wrangle-generated SLSA provenance against the goreleaser-
# produced dist directory by extracting the subject filename list
# from dist/checksums.txt and handing them to `slsa-verifier
# verify-artifact`.
#
# Why a separate script: the reusable workflow previously inlined
# this as a `run: |` block, which (a) wasn't testable and (b) had a
# subtle bug — globbing dist/ would include goreleaser-internal
# metadata files (artifacts.json, config.yaml, metadata.json) that
# aren't in checksums.txt and aren't provenance subjects, causing
# slsa-verifier to fail with "artifact hash does not match
# provenance subject." Parsing checksums.txt is the only correct
# source of the subject list.
#
# Used by `.github/workflows/build_and_publish_go.yml`'s verify job.
# Lives at build/actions/go/verify_provenance.sh (not under
# checks/ or release/) because verify is its own job in the reusable
# workflow with default permissions — different surface from either
# composite.
#
# Usage: build/actions/go/verify_provenance.sh <dist_dir> <provenance_path> <source_uri>
#
#   dist_dir:        path to the directory containing checksums.txt and the
#                    artifacts whose hashes are listed there
#   provenance_path: path to the .intoto.jsonl provenance bundle
#   source_uri:      e.g., "github.com/<owner>/<repo>" (passed to
#                    --source-uri so slsa-verifier binds the
#                    attestation to the source repo).

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
