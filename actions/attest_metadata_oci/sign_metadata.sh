#!/bin/bash
set -euo pipefail
set -f

# Sign the container build's SBOM + scan/v1 metadata for the image digest subject
# in the attest job, post each signed line to the GitHub attestation store, push
# each as its own by-digest OCI referrer (OCI_TARGET), and emit the signed set to
# OUT. Thin wrapper over lib/sign_metadata.sh's shared orchestration. Inputs
# (env): METADATA_ROOT, SUBJECTS, GITHUB_REPOSITORY, GITHUB_TOKEN, COMMIT, OUT,
# OCI_TARGET (see lib/sign_metadata.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
# shellcheck source=../../lib/env.sh
source "$LIB_DIR/env.sh"
# shellcheck source=../../lib/sign_metadata.sh
source "$LIB_DIR/sign_metadata.sh"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    wrangle_sign_and_emit_metadata
fi
