#!/bin/bash
set -euo pipefail
set -f

# Run bats tests, either against an explicit <bats-path> or by
# auto-detecting .bats files under <scan-path>.
#
# bats EXECUTES caller-supplied .bats files (arbitrary bash), a direct
# workflow-command-injection path: a test that printfs `::add-mask::SECRET`
# would hijack the build job. Both invocation paths run under
# stop_commands_guard.sh — see #225 / docs/SLSA_L3_AUDIT.md Finding 3.
#
# Usage: run_bats.sh <bats-path> <scan-path>
#   bats-path:  explicit path to .bats files, or "" to auto-detect.
#   scan-path:  subtree to auto-detect .bats files under (already
#               validated by run_shellcheck.sh, which runs first).

if [[ $# -ne 2 ]]; then
    printf 'Usage: run_bats.sh <bats-path> <scan-path>\n' >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../../../lib/stop_commands_guard.sh"
BATS_PATH="$1"
SCAN_PATH="$2"

printf '=== bats ===\n'

# Validate bats-path if provided: must be a relative path with only safe
# characters. Reject absolute paths and path traversal.
if [[ -n "$BATS_PATH" ]]; then
    if [[ "$BATS_PATH" == /* ]]; then
        printf 'bats: absolute paths not allowed: %s\n' "$BATS_PATH" >&2
        exit 1
    fi
    if [[ "$BATS_PATH" == *..* ]]; then
        printf 'bats: path traversal not allowed: %s\n' "$BATS_PATH" >&2
        exit 1
    fi
    if [[ ! "$BATS_PATH" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        printf 'bats: invalid characters in bats-path: %s\n' "$BATS_PATH" >&2
        exit 1
    fi
    "$GUARD" run bats "$BATS_PATH"
else
    # Auto-detect: find all .bats files under scan-path. scan-path was
    # validated by run_shellcheck.sh, which runs first.
    bats_files=()
    while IFS= read -r -d '' f; do
        bats_files+=("$f")
    done < <(find "$SCAN_PATH" -name '*.bats' -not -path '*/.git/*' -print0 2>/dev/null)

    if [[ ${#bats_files[@]} -gt 0 ]]; then
        "$GUARD" run bats "${bats_files[@]}"
    else
        printf 'bats: no .bats files found under %s, skipping\n' "$SCAN_PATH"
    fi
fi
