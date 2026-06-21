#!/bin/bash
set -euo pipefail
set -f

# Build the verify tools into WRANGLE_BIN_DIR: ampel (verify), bnd (sign), and
# wrangle-attest (build the unsigned scan/build statements) always; cosign (push
# the VSA as an OCI referrer) only when OCI_TARGET names a container image digest
# — npm/go/python verify never pushes, so it never needs cosign. Selecting the
# subset here avoids compiling the scan toolchain (osv-scanner et al.) verify
# never runs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pkgs=(
    github.com/carabiner-dev/ampel/cmd/ampel
    github.com/carabiner-dev/bnd
    github.com/TomHennen/wrangle/tools/wrangle-attest
)
if [[ -n "${OCI_TARGET:-}" ]]; then
    pkgs+=(github.com/sigstore/cosign/v3/cmd/cosign)
fi

"${SCRIPT_DIR}/../../lib/install_go_tools.sh" "${pkgs[@]}"
