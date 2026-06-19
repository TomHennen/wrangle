#!/bin/bash
set -euo pipefail
set -f

# Run the tag-gated keyless-signing integration test for wrangle-attest. Pins
# Go's proxy + sum database (lib/env.sh) so the build can't skip integrity
# checks; the ambient GitHub OIDC token the signer exchanges at Fulcio comes
# from the calling job's id-token: write.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/env.sh
source "$REPO_ROOT/lib/env.sh"

go -C "$REPO_ROOT/tools" test -tags keyless_integration -run TestRunSignKeyless ./wrangle-attest/...
