#!/bin/bash
set -euo pipefail
set -f

# Install the tools wrangle's integration bats suites need on top of the
# shell build type's own installs (shellcheck, bats): the Go tools from
# tools/go.mod (ampel, bnd, slsa-verifier, cosign — go.sum integrity) and
# osv-scanner (SLSA provenance, verified by the just-installed
# slsa-verifier). Single source of truth for those deps: consumed as the
# setup-script input of wrangle's own build_shell.yml call AND by
# `make integration` inside the test container (`./test.sh integration`).
#
# Requires go and jq on PATH (GitHub runner images and test/Dockerfile
# both provide them). Installs into $WRANGLE_BIN_DIR (lib/env.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/env.sh
source "$REPO_ROOT/lib/env.sh"

mkdir -p "$WRANGLE_BIN_DIR"

for tool in go jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'setup_integration: %s not on PATH (required)\n' "$tool" >&2
        exit 1
    fi
done

# Go tools first: slsa-verifier is needed by tools/osv/install.sh for
# provenance verification. It lives in its own module (tools/slsa-verifier/)
# because its year-old sigstore graph can't share tools/go.mod with cosign.
# env.sh pins GOPROXY/GOSUMDB so the sum database can't be disabled.
GOBIN="$WRANGLE_BIN_DIR" go -C "$REPO_ROOT/tools" install tool
GOBIN="$WRANGLE_BIN_DIR" go -C "$REPO_ROOT/tools/slsa-verifier" install tool

"$REPO_ROOT/tools/osv/install.sh"

# Later workflow steps (the shell build's bats step) run in fresh shells;
# the env.sh PATH export above only covers this process.
if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$WRANGLE_BIN_DIR" >> "$GITHUB_PATH"
fi

printf 'setup_integration: installed tool versions:\n'
osv-scanner --version | head -1
ampel version | head -1
slsa-verifier version 2>&1 | head -2 | tail -1
cosign version 2>&1 | grep GitVersion
