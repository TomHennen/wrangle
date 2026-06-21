#!/bin/bash
set -euo pipefail
set -f

# Build the named Go tool packages into WRANGLE_BIN_DIR via a single `go install`.
# Each argument is a full module package path (e.g. github.com/carabiner-dev/bnd);
# every wrangle tool builds from tools/go.mod, so versions route through go.sum.
# Callers select the subset they need so a job never compiles a toolchain it
# won't run. Downstream steps re-source lib/env.sh to find the binaries on PATH.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

if [[ "$#" -eq 0 ]]; then
    printf 'install_go_tools.sh: at least one package path is required\n' >&2
    exit 1
fi

GOBIN="$WRANGLE_BIN_DIR" go -C "${SCRIPT_DIR}/../tools" install "$@"
