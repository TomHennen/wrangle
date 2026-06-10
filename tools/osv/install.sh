#!/bin/bash
set -euo pipefail
set -f

# Install osv-scanner from tools/go.mod's pinned tool directive via
# `go install` — DEP_MGMT branch 1: a canonical Go module built by our
# own verified toolchain, bytes pinned by go.sum/sum.golang.org,
# version kept fresh by Dependabot. There is no foreign prebuilt binary
# in the chain, so there is nothing separate to attest.
#
# Requires go on PATH (GitHub runners and test/Dockerfile both provide it).
#
# Usage: install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL_NAME="osv-scanner"
TOOL_MODULE="github.com/google/osv-scanner/v2"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# Pin the module proxy + sum database at the install site so go.sum
# verification can't be disabled by an inherited GOSUMDB=off or a
# runner's `go env -w`.
export GOPROXY="https://proxy.golang.org,direct"
export GOSUMDB="sum.golang.org"

if ! command -v go >/dev/null 2>&1; then
    printf 'wrangle: go not on PATH (required to install %s)\n' "$TOOL_NAME" >&2
    exit 1
fi

# tools/go.mod is the single source of truth for the version.
VERSION="$(go -C "$TOOLS_DIR" list -m -f '{{.Version}}' "$TOOL_MODULE")"

# Check if the correct version is already installed. --version reports
# the bare semver ("osv-scanner version: 2.3.5") — extract the token and
# compare exactly: a substring match would let 2.3.50 satisfy 2.3.5.
if [[ -x "${BIN_DIR}/${TOOL_NAME}" ]]; then
    installed_version="$("${BIN_DIR}/${TOOL_NAME}" --version 2>/dev/null | head -1 | awk '{print $NF}' || true)"
    if [[ "$installed_version" == "${VERSION#v}" ]]; then
        printf 'wrangle: %s %s already installed\n' "$TOOL_NAME" "$VERSION"
        exit 0
    fi
fi

mkdir -p "$BIN_DIR"

# go requires an absolute GOBIN; WRANGLE_BIN_DIR may be CWD-relative.
# Retry with backoff: module downloads hit proxy.golang.org and the `go`
# command does not retry transient 5xx/network failures itself (the same
# flakiness the previous curl-based installer retried for — #190).
backoff=1
for attempt in 1 2 3; do
    if GOBIN="$(cd "$BIN_DIR" && pwd)" go -C "$TOOLS_DIR" install "${TOOL_MODULE}/cmd/osv-scanner"; then
        printf 'wrangle: installed %s %s (go.sum-verified build from tools/go.mod)\n' "$TOOL_NAME" "$VERSION"
        exit 0
    fi
    if [[ "$attempt" -lt 3 ]]; then
        printf 'wrangle: go install attempt %d/3 failed, retrying in %ds...\n' "$attempt" "$backoff" >&2
        sleep "$backoff"
        backoff=$((backoff * 2))
    fi
done
printf 'wrangle: FATAL: go install failed for %s after 3 attempts\n' "$TOOL_NAME" >&2
exit 1
