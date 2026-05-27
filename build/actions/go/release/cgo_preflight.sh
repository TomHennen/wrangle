#!/bin/bash
# Pre-flight that inspects .goreleaser.yml for cgo + cross-compile
# patterns and decides what wrangle needs to do before goreleaser runs:
#
#   - If the adopter has set `CC=zig ...` (or `CXX=zig ...`) anywhere
#     in a builds[].env entry, signal install-zig=true so the release
#     composite installs zig before goreleaser invocation. Wrangle
#     owns the toolchain so the adopter's .goreleaser.yml stays short
#     (per-cell `CC=zig cc -target X` templates, no install plumbing).
#
#   - If the adopter has CGO_ENABLED=1 with non-amd64 or non-linux
#     build cells AND no cross-toolchain hint (no CC=zig and no other
#     CC= override), emit a workflow ::warning:: naming the failure
#     mode and pointing at the cgo example. Goreleaser will fail
#     loudly anyway; the warning makes the cause discoverable.
#
# Implementation: yq -o json | jq. yq converts YAML to JSON; jq does
# the actual selection. jq's filter language handles default values,
# null safety, and Cartesian iteration cleanly — earlier grep-based
# attempts (#270 first revision) needed multiple sanitizers and still
# false-positived on comments and `ignore:` blocks.
#
# Required tools: yq (mikefarah's, v4.x) and jq. Both are preinstalled
# on ubuntu-latest, and the test image installs them too (see
# test/Dockerfile). If either is missing the preflight degrades to a
# no-op with a debug log — wrangle's release composite does not
# install yq itself; it relies on the runner image.
#
# Output: writes `install-zig=true|false` to $GITHUB_OUTPUT. Always
# exits 0 — the preflight is advisory and must never block the
# release.
#
# Usage: build/actions/go/release/cgo_preflight.sh <project-dir>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <project-dir>\n' "$0" >&2
    exit 1
fi

PROJECT_DIR="$1"

# Helper: append a key=value to $GITHUB_OUTPUT if set, else print to
# stdout (so tests can capture the value without simulating GHA).
write_output() {
    local key="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$key" "$value"
    fi
}

# Resolve config path (mirrors validate_inputs.sh's enforcement order).
CONFIG=""
if [[ -f "$PROJECT_DIR/.goreleaser.yml" ]]; then
    CONFIG="$PROJECT_DIR/.goreleaser.yml"
elif [[ -f "$PROJECT_DIR/.goreleaser.yaml" ]]; then
    CONFIG="$PROJECT_DIR/.goreleaser.yaml"
fi
if [[ -z "$CONFIG" ]]; then
    # validate_inputs.sh already enforces presence; defensive no-op.
    write_output "install-zig" "false"
    exit 0
fi

# Required tools. Either missing → advisory no-op rather than break
# the release. On ubuntu-latest both are preinstalled; if a future
# runner image drops yq, this branch keeps the release working while
# emitting a debug log that explains the missing preflight.
# stdout (not stderr) because GitHub Actions workflow commands
# (::debug::, ::warning::) must be on the runner's read stream.
for tool in yq jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '::debug::cgo_preflight: %s not on PATH; skipping advisory preflight\n' "$tool"
        write_output "install-zig" "false"
        exit 0
    fi
done

# Convert YAML to JSON once; downstream jq queries operate on that.
JSON_CONFIG=""
if ! JSON_CONFIG="$(yq -o json "$CONFIG" 2>/dev/null)"; then
    printf '::debug::cgo_preflight: %s is not parseable as YAML; skipping\n' "$CONFIG"
    write_output "install-zig" "false"
    exit 0
fi

# Signal 1: zig as cross-compiler. Match `CC=zig` or `CXX=zig` (with
# optional whitespace around `=`) in any builds[].env entry. The
# anchored pattern avoids false positives like `MY_ZIG_PATH=...`.
NEEDS_ZIG="false"
if printf '%s' "$JSON_CONFIG" \
    | jq -r '.builds[]?.env[]? // empty' \
    | grep -qE '^[[:space:]]*(CC|CXX)[[:space:]]*=[[:space:]]*zig([[:space:]]|$)'; then
    NEEDS_ZIG="true"
fi
write_output "install-zig" "$NEEDS_ZIG"

# Signal 2 (warning) is suppressed when wrangle is installing zig.
if [[ "$NEEDS_ZIG" == "true" ]]; then
    exit 0
fi

# Suppression: any other CC=/CXX= override (musl-gcc, mingw, etc.)
# means the adopter has wired their own cross-toolchain. Stay quiet.
if printf '%s' "$JSON_CONFIG" \
    | jq -r '.builds[]?.env[]? // empty' \
    | grep -qE '^[[:space:]]*(CC|CXX)[[:space:]]*='; then
    exit 0
fi

# Effective goos/goarch per build with goreleaser's defaults applied
# (goos = [linux, darwin, windows], goarch = [amd64, arm64, "386"]).
# For each build that sets CGO_ENABLED=1, iterate over the cell
# (goos, goarch) cartesian and emit any cell that isn't linux/amd64.
NON_NATIVE_CELL="$(printf '%s' "$JSON_CONFIG" | jq -r '
    .builds[]?
    | select((.env // []) | any(. == "CGO_ENABLED=1"))
    | (.goos // ["linux","darwin","windows"])[] as $os
    | (.goarch // ["amd64","arm64","386"])[] as $arch
    | $os + "/" + $arch
    | select(. != "linux/amd64")
' 2>/dev/null | head -1 || true)"

if [[ -n "$NON_NATIVE_CELL" ]]; then
    printf '::warning title=cgo + cross-compile may fail on ubuntu-latest::%s\n' \
        "Your .goreleaser.yml sets CGO_ENABLED=1 with a non-linux/amd64 target (e.g., $NON_NATIVE_CELL). The default ubuntu-latest runner has an amd64-only C toolchain; goreleaser's cgo build for other cells will fail with opaque '# runtime/cgo' assembler errors. Fix options: (a) set CGO_ENABLED=0 (Go cross-compiles freely without cgo), (b) restrict goos/goarch to linux/amd64, or (c) set CC=zig cc -target ... templates in your env block — wrangle then installs zig automatically. Working example: gh_workflow_examples/build_go_cgo.goreleaser.yml."
fi

exit 0
