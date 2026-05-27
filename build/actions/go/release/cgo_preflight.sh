#!/bin/bash
# Advisory pre-flight that warns when .goreleaser.yml configures
# CGO_ENABLED=1 with a build matrix the default ubuntu-latest runner
# cannot cross-compile (anything outside linux/amd64). The runner ships
# an amd64-only gcc; cgo to linux/arm64 or any darwin/windows target
# fails inside goreleaser with cryptic `# runtime/cgo` assembler
# errors. We surface a workflow warning that names the failure mode
# and points at the cgo example, so adopters don't burn 10 minutes
# decoding `gcc_arm64.S: Error: no such instruction: 'stp ...'`.
#
# This is best-effort by design: grep-level detection, advisory only,
# always exits 0. False negatives (missed config shapes) are acceptable
# — goreleaser will still fail loudly. False positives (warning when
# the adopter already wired a cross-toolchain) are suppressed by a
# coarse "looks like cgo cross-toolchain is set up" heuristic.
#
# Usage: build/actions/go/release/cgo_preflight.sh <project-dir>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <project-dir>\n' "$0" >&2
    exit 1
fi

PROJECT_DIR="$1"

CONFIG=""
if [[ -f "$PROJECT_DIR/.goreleaser.yml" ]]; then
    CONFIG="$PROJECT_DIR/.goreleaser.yml"
elif [[ -f "$PROJECT_DIR/.goreleaser.yaml" ]]; then
    CONFIG="$PROJECT_DIR/.goreleaser.yaml"
else
    # validate_inputs.sh already enforced presence; defensive no-op.
    exit 0
fi

# Strip noise before pattern-matching:
#   - YAML comment lines (an adopter commenting out `CGO_ENABLED=1`
#     or documenting goos targets in prose would otherwise trip the
#     pattern grep).
#   - `ignore:` blocks (goreleaser's standard way of *excluding* a
#     (goos, goarch) cell; counting those cells would warn on the
#     exact case where the adopter already did the right thing).
# Output goes to stdout for downstream `grep -qE` to consume via
# process substitution.
sanitize() {
    awk '
        # Drop full-line YAML comments. (Inline trailing `# ...`
        # comments are intentionally kept — they'\''re a small share
        # of the false-positive surface and stripping them properly
        # requires distinguishing `#` inside quoted strings.)
        /^[[:space:]]*#/ { next }

        # Skip lines belonging to an `ignore:` block. Block starts
        # with `ignore:` at some indent; ends when a non-blank line
        # returns to that indent or shallower.
        in_ignore {
            if ($0 ~ /^[[:space:]]*$/) next
            match($0, /^ */); col = RLENGTH
            if (col > ignore_col) next
            in_ignore = 0
        }
        /^[[:space:]]*ignore:[[:space:]]*$/ {
            in_ignore = 1
            match($0, /^ */); ignore_col = RLENGTH
            next
        }

        { print }
    ' "$CONFIG"
}

# CGO_ENABLED=1 in any env: list (block or flow style). Matches the
# common shapes: `- CGO_ENABLED=1`, `CGO_ENABLED: "1"`, flow-style
# `env: [CGO_ENABLED=1]`, with optional surrounding quotes/whitespace.
# The trailing `[^0-9a-zA-Z_]|$` guard rejects `CGO_ENABLED=10` /
# `CGO_ENABLED=1true` etc. while allowing flow-list terminators
# (`]`, `,`) and trailing punctuation.
has_cgo_enabled() {
    grep -qE "CGO_ENABLED[[:space:]]*[:=][[:space:]]*[\"']?1[\"']?([^0-9a-zA-Z_]|$)" < <(sanitize)
}

# Any target the runner can't natively cross-compile cgo for.
# linux/amd64 is the runner's native — everything else needs a
# cross-toolchain. Match goos/goarch lines in both flow style
# (`goos: [linux, darwin]`) and block style (`- darwin`).
has_non_native_target() {
    local stripped
    stripped="$(sanitize)"
    grep -qE "goos:.*(darwin|windows)" <<<"$stripped" && return 0
    grep -qE "goarch:.*(arm64|arm|386|riscv64|mips|s390x|ppc64)" <<<"$stripped" && return 0
    # Block-style list items under goos:/goarch:. The grep is coarse —
    # a stray top-level `- darwin` would match. False positives here
    # are still real warnings (the adopter is doing something this
    # preflight wasn't designed for).
    grep -qE "^[[:space:]]+-[[:space:]]+(darwin|windows|arm64|riscv64|s390x|ppc64)([[:space:]]|$)" <<<"$stripped" && return 0
    return 1
}

# Heuristic: if the config already references a cross-toolchain
# (zig, goreleaser-cross, an apt cross-gcc triple, or explicit
# CC=/CXX= overrides), stay silent — the adopter knows what they're
# doing. Misses are acceptable (we just warn redundantly).
has_cross_toolchain_hint() {
    local stripped
    stripped="$(sanitize)"
    grep -qE "zig[[:space:]]+cc|zig[[:space:]]+c\+\+|goreleaser-cross|aarch64-linux-gnu-gcc|x86_64-linux-musl|o64-clang|oa64-clang" <<<"$stripped" && return 0
    grep -qE "^[[:space:]]*-[[:space:]]+(CC|CXX)[[:space:]]*=" <<<"$stripped" && return 0
    return 1
}

if has_cgo_enabled && has_non_native_target && ! has_cross_toolchain_hint; then
    # Single-line ::warning:: — multi-line content is allowed but
    # only via the `%0A` URL-encoded newline; keep it readable in
    # the Actions UI by sticking to one line.
    printf '::warning title=cgo + cross-compile may fail on ubuntu-latest::%s\n' \
        "Your .goreleaser.yml sets CGO_ENABLED=1 with a non-linux or non-amd64 target. The default ubuntu-latest runner has an amd64-only C toolchain; goreleaser's cgo build for the other cells will fail with opaque '# runtime/cgo' assembler errors. Fix options: (a) set CGO_ENABLED=0 (Go cross-compiles freely without cgo), (b) restrict goos/goarch to linux/amd64, or (c) wire a cross-compile toolchain like zig — see gh_workflow_examples/build_go_cgo.goreleaser.yml for the working pattern."
fi

exit 0
