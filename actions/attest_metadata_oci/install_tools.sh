#!/bin/bash
set -euo pipefail
set -f

# Build the container attest-job metadata-signing tools into WRANGLE_BIN_DIR:
# wrangle-attest (build the SBOM + scan/v1 statements), bnd (keyless-sign + push
# to the GitHub attestation store), and cosign (push each signed line as a
# by-digest OCI referrer on the image). This job signs metadata but does not run
# ampel (no verdict here) — that stays in verify.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/../../lib/install_go_tools.sh" \
    github.com/TomHennen/wrangle/tools/wrangle-attest \
    github.com/carabiner-dev/bnd \
    github.com/sigstore/cosign/v3/cmd/cosign
