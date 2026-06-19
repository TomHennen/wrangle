#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles image refs and paths
# Extract the SPDX SBOM from a built image and write the wrangle-attest manifest
# next to it so the verify-stage engine produces an SBOM attestation.
#
# Usage: extract_sbom.sh <image-ref> <metadata-dir> <github-output>
#   <image-ref>     image referenced by digest (tag-only refs miss non-main builds)
#   <metadata-dir>  dir the SBOM + wrangle_attestation_metadata.json are written to
#   <github-output> $GITHUB_OUTPUT to record the sbom path on

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRANGLE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

main() {
    if [[ "$#" -ne 3 ]]; then
        printf 'Usage: %s <image-ref> <metadata-dir> <github-output>\n' "${0##*/}" >&2
        return 2
    fi
    local image_ref="$1" metadata_dir="$2" github_output="$3"
    local sbom_path="${metadata_dir}/sbom.spdx.json"

    docker buildx imagetools inspect "$image_ref" --format "{{ json .SBOM.SPDX }}" > "$sbom_path"
    "$WRANGLE_ROOT/lib/write_attest_manifest.sh" \
        "$metadata_dir" "https://spdx.dev/Document" "sbom.spdx.json"
    printf 'sbom=%s\n' "$sbom_path" >> "$github_output"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
