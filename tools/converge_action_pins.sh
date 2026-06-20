#!/bin/bash
set -euo pipefail
set -f

# Drive wrangle self-ref pins to convergence: if check_pin_ancestry is red,
# bump every pin to HEAD, commit, and repeat until it's green. A nested chain
# needs one commit per level (a commit can't pin itself), so this can emit >1
# commit — land them as a MERGE COMMIT or a direct push to main, never a squash,
# or the intermediate pins re-orphan. No-op (0 commits) when already green.
# Requires a clean working tree; commits on the current branch; does not push.
#
# Usage: tools/converge_action_pins.sh
# Env: WRANGLE_CONVERGE_MAX_ITERS (default 10); bump_action_pins.sh's
#      WRANGLE_PINS_* pass through.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bump="$SCRIPT_DIR/bump_action_pins.sh"
check="$SCRIPT_DIR/check_pin_ancestry.sh"

repo_root="$(git rev-parse --show-toplevel)" || {
    printf 'converge_action_pins: not inside a git work tree\n' >&2
    exit 2
}

if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
    printf 'converge_action_pins: working tree not clean; commit or stash first\n' >&2
    exit 2
fi

if "$check" >/dev/null 2>&1; then
    printf 'converge_action_pins: already converged (0 commits).\n'
    exit 0
fi

max_iters="${WRANGLE_CONVERGE_MAX_ITERS:-10}"
commits=0
converged=false
for ((i = 1; i <= max_iters; i++)); do
    "$bump" "$(git -C "$repo_root" rev-parse HEAD)" >/dev/null
    if git -C "$repo_root" diff --quiet; then
        # Bumping to HEAD changed nothing yet the check is still red: no prior
        # commit carries a reachable nested pin, so no bump can resolve it.
        printf 'converge_action_pins: cannot converge — bump is a no-op but the check is still red\n' >&2
        break
    fi
    git -C "$repo_root" commit -qam "chore: converge self-ref pins (cycle $i)"
    commits=$((commits + 1))
    if "$check" >/dev/null 2>&1; then
        converged=true
        break
    fi
done

if [[ "$converged" != true ]]; then
    printf 'converge_action_pins: not converged after %d commit(s); check_pin_ancestry:\n' "$commits" >&2
    "$check" >&2 || true
    exit 1
fi

printf 'converge_action_pins: converged in %d commit(s).\n' "$commits"
if [[ "$commits" -gt 1 ]]; then
    printf 'NOTE: %d commits — land as a merge commit or a direct push to main, NOT a squash, or the intermediate pins re-orphan.\n' "$commits"
fi
