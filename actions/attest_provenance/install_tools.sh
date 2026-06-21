#!/bin/bash
set -euo pipefail
set -f

# Build the attest-job signing tools into WRANGLE_BIN_DIR: wrangle-attest (build
# the SBOM + scan/v1 statements) and bnd (keyless-sign + push to the GitHub
# attestation store). attest runs neither ampel (no verdict here) nor cosign (no
# OCI push), so it builds only this pair — not the verify or scan toolchains.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/../../lib/install_go_tools.sh" \
    github.com/TomHennen/wrangle/tools/wrangle-attest \
    github.com/carabiner-dev/bnd
