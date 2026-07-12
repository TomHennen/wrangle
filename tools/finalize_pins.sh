#!/bin/bash
set -euo pipefail
set -f

# finalize_pins.sh — roll the declared self-ref pins onto main's first-parent
# history, labelled `# main` (cut-release runbook, Phase 1, last step).
#
# Usage: finalize_pins.sh [<main-sha>]      default: current origin/main
#
# Why this exists as a script rather than a documented command: an in-PR converge
# necessarily pins branch commits, and main's first-parent line is all merge
# commits — a merge SHA cannot exist before the merge. So the pins can only reach
# first-parent history in a second step, after the merge. That step is easy to
# forget, and easy to get subtly wrong: `bump_action_pins.sh` writes the *current
# branch's* name as the label unless the target is reachable from origin/main, so
# converging from a feature branch silently produces `# some-branch` pins. Both
# mistakes were made by hand while cutting v0.4.0.
#
# The result must be opened as a PR: direct pushes to main are blocked, and the
# converge commits must land as a MERGE COMMIT, never a squash, or the
# intermediate pins re-orphan.
#
# Exit: 0 finalized (or already finalized), 1 the finalize did not take, 2 usage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${WRANGLE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

wrangle_die() { printf 'finalize_pins: %s\n' "$1" >&2; return 1; }

# The target must be ON main's first-parent line, or the pins land right back
# where they started.
wrangle_check_first_parent() {
    local sha="$1"
    git -C "$REPO_ROOT" rev-list --first-parent origin/main \
        | grep -qx "$sha" \
        || wrangle_die "target ${sha:0:9} is not on origin/main's first-parent history — pass a merge commit from main"
}

wrangle_finalize_pins() {
    local target="${1:-}"

    git -C "$REPO_ROOT" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main

    if [[ -z "$target" ]]; then
        target="$(git -C "$REPO_ROOT" rev-parse origin/main)"
    else
        target="$(git -C "$REPO_ROOT" rev-parse "$target")"
    fi
    wrangle_check_first_parent "$target"

    # WRANGLE_PINS_BRANCH=main is the whole point: without it the label follows
    # the current branch and the pins come out `# some-branch`.
    WRANGLE_PINS_BRANCH=main "$SCRIPT_DIR/bump_action_pins.sh" "$target" \
        || wrangle_die "bump_action_pins failed"

    if ! "$SCRIPT_DIR/check_pin_main_history.sh"; then
        wrangle_die "pins are still not on main's first-parent history — do not cut"
    fi
    "$SCRIPT_DIR/check_pin_freshness.sh" >/dev/null \
        || wrangle_die "pins resolve stale content after the finalize"

    if git -C "$REPO_ROOT" diff --quiet; then
        printf 'finalize_pins: already finalized at %s — nothing to do\n' "${target:0:9}"
        return 0
    fi

    printf '\nfinalize_pins: pins rolled onto %s, labelled # main.\n' "${target:0:9}"
    printf 'Commit these and open a PR. Merge it as a MERGE COMMIT, not a squash.\n'
}

main() {
    [[ $# -le 1 ]] || { printf 'Usage: finalize_pins.sh [<main-sha>]\n' >&2; exit 2; }
    wrangle_finalize_pins "${1:-}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
