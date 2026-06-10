#!/bin/bash
set -euo pipefail
set -f

# Install osv-scanner via `go install` from tools/go.mod's pinned tool
# directive (go.sum integrity, Dependabot freshness). The other Go tools
# have no install script — this one exists only because the adapter
# contract has run.sh call tools/<name>/install.sh.
#
# Requires go on PATH (GitHub runners and test/Dockerfile both provide it).
#
# Usage: install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# Pin the module proxy + sum database at the install site so go.sum
# verification can't be disabled by an inherited GOSUMDB=off or a
# runner's `go env -w`.
export GOPROXY="https://proxy.golang.org,direct"
export GOSUMDB="sum.golang.org"

if ! command -v go >/dev/null 2>&1; then
    printf 'wrangle: go not on PATH (required to install osv-scanner)\n' >&2
    exit 1
fi

mkdir -p "$BIN_DIR"

# go requires an absolute GOBIN; WRANGLE_BIN_DIR may be CWD-relative.
# Retry with backoff: module downloads hit proxy.golang.org and the `go`
# command does not retry transient 5xx/network failures itself (the same
# flakiness the previous curl-based installer retried for — #190).
# Re-runs are cheap: an unchanged pin rebuilds from go's build cache.
backoff=1
for attempt in 1 2 3; do
    if GOBIN="$(cd "$BIN_DIR" && pwd)" go -C "$TOOLS_DIR" install github.com/google/osv-scanner/v2/cmd/osv-scanner; then
        printf 'wrangle: installed osv-scanner (go.sum-verified build from tools/go.mod)\n'
        exit 0
    fi
    if [[ "$attempt" -lt 3 ]]; then
        printf 'wrangle: go install attempt %d/3 failed, retrying in %ds...\n' "$attempt" "$backoff" >&2
        sleep "$backoff"
        backoff=$((backoff * 2))
    fi
done
printf 'wrangle: FATAL: go install failed for osv-scanner after 3 attempts\n' >&2
exit 1
