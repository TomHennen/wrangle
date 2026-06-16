#!/bin/bash
set -euo pipefail
set -f

# Build the verify tools into WRANGLE_BIN_DIR: ampel (verify) and bnd (sign)
# always; cosign (push the VSA as an OCI referrer) only when OCI_TARGET names a
# container image digest — npm/go/python verify never pushes, so it never needs
# cosign. Installing the rest of the tool manifest here would compile the scan
# toolchain (osv-scanner et al.) that verify never runs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/env.sh
source "${SCRIPT_DIR}/../../lib/env.sh"

pkgs=(
    github.com/carabiner-dev/ampel/cmd/ampel
    github.com/carabiner-dev/bnd
)
if [[ -n "${OCI_TARGET:-}" ]]; then
    pkgs+=(github.com/sigstore/cosign/v3/cmd/cosign)
fi

GOBIN="$WRANGLE_BIN_DIR" go -C "${SCRIPT_DIR}/../../tools" install "${pkgs[@]}"
