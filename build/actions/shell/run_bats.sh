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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../../../lib/stop_commands_guard.sh"
VALIDATE_PATH="$SCRIPT_DIR/../../../lib/validate_path.sh"

# BATS_JOBS files run concurrently via GNU parallel (bats' --jobs requires
# it); within-file order is always preserved so a file's setup assumptions
# hold. Defaults to 1 (serial). Parallelism is opt-in — an adopter suite may
# share cross-file state. Falls back to serial with a warning when >1 is asked
# for but GNU parallel is absent.
compute_bats_opts() {
    BATS_OPTS=()
    local jobs="${BATS_JOBS:-1}"
    if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
        printf 'run_bats.sh: bats-jobs must be a positive integer, got %q\n' "$jobs" >&2
        exit 1
    fi
    [[ "$jobs" -gt 1 ]] || return 0
    if ! command -v parallel >/dev/null 2>&1; then
        printf 'run_bats.sh: bats-jobs=%s but GNU parallel is absent; running serially\n' "$jobs" >&2
        return 0
    fi
    BATS_OPTS=(--jobs "$jobs" --no-parallelize-within-files)
}

main() {
    if [[ $# -ne 2 ]]; then
        printf 'Usage: run_bats.sh <bats-path> <scan-path>\n' >&2
        exit 1
    fi

    local BATS_PATH="$1"
    local SCAN_PATH="$2"

    printf '=== bats ===\n'

    compute_bats_opts

    # Validate every bats-path entry via the shared allowlist (relative, no
    # traversal, safe charset); lib/validate_path.sh exits non-zero and set -e
    # aborts here. scan-path is validated by run_shellcheck.sh, which runs
    # first. Newlines/tabs are normalized to spaces first — a YAML block-scalar
    # input arrives newline-separated, and `read -a` would otherwise silently
    # drop everything after the first line. The split is safe under set -f (no
    # glob expansion), and the allowlist charset has no whitespace, so entries
    # can't contain hidden separators.
    if [[ -n "${BATS_PATH//[[:space:]]/}" ]]; then
        local bats_paths
        read -r -a bats_paths <<< "${BATS_PATH//[[:space:]]/ }"
        local p
        for p in "${bats_paths[@]}"; do
            "$VALIDATE_PATH" "$p"
        done
        "$GUARD" run bats "${BATS_OPTS[@]}" "${bats_paths[@]}"
    else
        # Auto-detect: find all .bats files under scan-path. scan-path was
        # validated by run_shellcheck.sh, which runs first.
        local bats_files=()
        local f
        while IFS= read -r -d '' f; do
            bats_files+=("$f")
        done < <(find "$SCAN_PATH" -name '*.bats' -not -path '*/.git/*' -print0 2>/dev/null)

        if [[ ${#bats_files[@]} -gt 0 ]]; then
            "$GUARD" run bats "${BATS_OPTS[@]}" "${bats_files[@]}"
        else
            printf 'bats: no .bats files found under %s, skipping\n' "$SCAN_PATH"
        fi
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
