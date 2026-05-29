#!/bin/bash
# Coarse warning: if the adopter's .goreleaser.yml contains CGO_ENABLED=1
# and they haven't passed install-zig: true to the reusable workflow,
# emit a ::warning:: that names the input. Goreleaser will still fail
# loudly on cross-OS / non-amd64 builds; this just makes the cause
# discoverable and points at the escape hatch.
#
# False positives (e.g., a commented-out CGO_ENABLED=1) cost the
# adopter one re-read of the warning, not a build failure — so grep
# is fine; no yq/jq parser needed.
#
# Usage: build/actions/go/release/cgo_warning.sh <project-dir>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <project-dir>\n' "$0" >&2
    exit 1
fi

PROJECT_DIR="$1"

for f in "$PROJECT_DIR/.goreleaser.yml" "$PROJECT_DIR/.goreleaser.yaml"; do
    if [[ -f "$f" ]] && grep -qE 'CGO_ENABLED[[:space:]]*[:=][[:space:]]*"?1"?' "$f"; then
        printf '::warning title=cgo + cross-compile may fail on ubuntu-latest::%s\n' \
            "Your .goreleaser.yml sets CGO_ENABLED=1. The ubuntu-latest runner has an amd64-only C toolchain; cgo builds for linux/arm64, darwin/*, or windows/* fail with opaque '# runtime/cgo' assembler errors. Pass install-zig: true to the reusable workflow (zig acts as a drop-in C cross-compiler) and set per-cell CC=zig cc -target <triple> in your env block. Working example: gh_workflow_examples/build_go_cgo.goreleaser.yml. See build/actions/go/README.md 'Cross-compiling with cgo'."
        break
    fi
done
