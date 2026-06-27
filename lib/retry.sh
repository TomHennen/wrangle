#!/bin/bash
set -euo pipefail
set -f

# lib/retry.sh — shared retry helper for transient network/registry/Sigstore I/O.

# Run a command, retrying once on failure to absorb a transient blip. The
# command's stdout is captured to $1 (truncated per attempt) so the caller
# evaluates only the surviving attempt's output; re-evaluation is deterministic,
# so a retry can only flip a transient failure, never manufacture a good result.
# WRANGLE_RETRY_DELAY spaces the attempts (tests set it to 0).
wrangle_retry_once() {
    local out="$1"; shift
    "$@" > "$out" && return 0
    local rc=$?
    printf 'wrangle: %s failed (exit %s); retrying once for transient Sigstore I/O\n' "$1" "$rc" >&2
    sleep "${WRANGLE_RETRY_DELAY:-5}"
    "$@" > "$out"
}
