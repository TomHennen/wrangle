#!/bin/bash
set -euo pipefail
set -f

# Run bats tests, either against explicit <bats-path> entries or by
# auto-detecting .bats files under <scan-path>.
#
# bats EXECUTES caller-supplied .bats files (arbitrary bash), a direct
# workflow-command-injection path: a test that printfs `::add-mask::SECRET`
# would hijack the build job. Both invocation paths run under
# stop_commands_guard.sh — see #225 / docs/SLSA_L3_AUDIT.md Finding 3.
#
# Usage: run_bats.sh <bats-path> <scan-path>
#   bats-path:  space-separated path(s) to .bats files or directories,
#               or "" to auto-detect.
#   scan-path:  subtree to auto-detect .bats files under (already
#               validated by run_shellcheck.sh, which runs first).

if [[ $# -ne 2 ]]; then
    printf 'Usage: run_bats.sh <bats-path> <scan-path>\n' >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../../../lib/stop_commands_guard.sh"
VALIDATE_PATH="$SCRIPT_DIR/../../../lib/validate_path.sh"
BATS_PATH="$1"
SCAN_PATH="$2"

printf '=== bats ===\n'

# Validate every bats-path entry via the shared allowlist (relative, no
# traversal, safe charset); lib/validate_path.sh exits non-zero and set -e
# aborts here. scan-path is validated by run_shellcheck.sh, which runs first.
# Newlines/tabs are normalized to spaces first — a YAML block-scalar input
# arrives newline-separated, and `read -a` would otherwise silently drop
# everything after the first line. The split is safe under set -f (no glob
# expansion), and the allowlist charset has no whitespace, so entries
# can't contain hidden separators.
if [[ -n "${BATS_PATH//[[:space:]]/}" ]]; then
    read -r -a bats_paths <<< "${BATS_PATH//[[:space:]]/ }"
    for p in "${bats_paths[@]}"; do
        "$VALIDATE_PATH" "$p"
    done
    "$GUARD" run bats "${bats_paths[@]}"
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
