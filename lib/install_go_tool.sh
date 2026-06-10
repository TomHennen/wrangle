#!/bin/bash
set -euo pipefail
set -f

# Install one Go tool from tools/go.mod into $WRANGLE_BIN_DIR.
#
# The generic install path for adapter-pattern tools: a tool ships a
# one-line tools/<name>/go-tool file naming its package, and run.sh calls
# this instead of a per-tool install.sh. The package MUST be declared as a
# tool directive in tools/go.mod — that manifest (plus go.sum) is the
# single source for version and integrity, and Dependabot keeps it fresh.
# A per-tool install.sh remains the escape hatch for tools no package
# manager ships (see DEP_MGMT.md).
#
# Usage: install_go_tool.sh <package-path>

if [[ $# -ne 1 ]]; then
    printf 'Usage: install_go_tool.sh <package-path>\n' >&2
    exit 1
fi

PKG="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# The package path flows into a command line: allowlist its charset, and
# require it to be a declared tool directive so this script can only ever
# build what tools/go.mod pins.
if [[ ! "$PKG" =~ ^[a-zA-Z0-9][a-zA-Z0-9./_-]*$ ]]; then
    printf 'wrangle: invalid go tool package path: %s\n' "$PKG" >&2
    exit 1
fi
if ! grep -qF "$PKG" "$TOOLS_DIR/go.mod"; then
    printf 'wrangle: %s is not a tool directive in tools/go.mod\n' "$PKG" >&2
    exit 1
fi

if ! command -v go >/dev/null 2>&1; then
    printf 'wrangle: go not on PATH (required to install %s)\n' "$PKG" >&2
    exit 1
fi

# Pin the module proxy + sum database at the install site so go.sum
# verification can't be disabled by an inherited GOSUMDB=off or a
# runner's `go env -w`.
export GOPROXY="https://proxy.golang.org,direct"
export GOSUMDB="sum.golang.org"

mkdir -p "$BIN_DIR"

# go requires an absolute GOBIN; WRANGLE_BIN_DIR may be CWD-relative.
# Retry with backoff: module downloads hit proxy.golang.org and the `go`
# command does not retry transient 5xx/network failures itself (#190).
# Re-runs are cheap: an unchanged pin rebuilds from go's build cache.
backoff=1
for attempt in 1 2 3; do
    if GOBIN="$(cd "$BIN_DIR" && pwd)" go -C "$TOOLS_DIR" install "$PKG"; then
        printf 'wrangle: installed %s (go.sum-verified build from tools/go.mod)\n' "$PKG"
        exit 0
    fi
    if [[ "$attempt" -lt 3 ]]; then
        printf 'wrangle: go install attempt %d/3 failed, retrying in %ds...\n' "$attempt" "$backoff" >&2
        sleep "$backoff"
        backoff=$((backoff * 2))
    fi
done
printf 'wrangle: FATAL: go install failed for %s after 3 attempts\n' "$PKG" >&2
exit 1
