#!/bin/bash
set -euo pipefail
set -f

# Sign the build metadata (SBOM + scan/v1) for every dist subject in the attest
# job and assemble each subject's <artifact>.intoto.jsonl bundle (provenance
# from BUNDLE_IN + that subject's signed metadata) into BUNDLE_OUT (go/npm/python;
# no OCI_TARGET, so store delivery only). Thin wrapper over lib/sign_metadata.sh's
# shared orchestration. Inputs (env): METADATA_ROOT, SUBJECTS, GITHUB_REPOSITORY,
# GITHUB_TOKEN, COMMIT, BUNDLE_IN, BUNDLE_OUT (see lib/sign_metadata.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
# shellcheck source=../../lib/env.sh
source "$LIB_DIR/env.sh"
# shellcheck source=../../lib/sign_metadata.sh
source "$LIB_DIR/sign_metadata.sh"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    wrangle_sign_and_assemble_bundles
fi
