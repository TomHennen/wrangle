#!/usr/bin/env bash
# Install ampel and cosign at the versions pinned in tools/go.mod, onto PATH for
# later steps. tools/go.mod is the single source of truth for these pins
# (branch-1 / Dependabot-covered per DEP_MGMT.md), so there is no second checksum
# to drift; env.sh asserts GOPROXY/GOSUMDB so sum-database verification can't be
# disabled by the runner's environment.
set -euo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../lib/env.sh
source "$REPO_ROOT/lib/env.sh"

mkdir -p "$WRANGLE_BIN_DIR"
GOBIN="$(cd "$WRANGLE_BIN_DIR" && pwd)" go -C "$REPO_ROOT/tools" install \
    github.com/carabiner-dev/ampel/cmd/ampel \
    github.com/sigstore/cosign/v3/cmd/cosign

# Later composite steps run in fresh shells; env.sh's PATH export covers only
# this process.
if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$WRANGLE_BIN_DIR" >> "$GITHUB_PATH"
fi

printf 'verify-showcase-recipes: installed:\n'
ampel version | head -1
cosign version 2>&1 | grep GitVersion
