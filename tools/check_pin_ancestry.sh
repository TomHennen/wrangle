#!/bin/bash
set -euo pipefail
set -f

# tools/check_pin_ancestry.sh — fail if any wrangle self-reference action pin
# under .github/workflows is not reachable from HEAD.
#
# Why this exists: a "bootstrap pin" (see test/integration/SPEC.md §Known
# limitations) points a nested `TomHennen/wrangle/...@<sha>` self-reference at a
# BRANCH sha so the integration test can exercise an action/policy change that
# is not yet on main. That pin is reachable from HEAD on the PR branch (so this
# check is green there), but a SQUASH merge orphans the branch sha — after which
# release-showcase.yml (which tags every push to main) and any other main-side
# caller can no longer resolve the action. This check turns that silent
# post-merge breakage into a red CI check that forces the re-bump
# (tools/bump_action_pins.sh <main-sha>).
#
# Reachable-from-HEAD is the correct invariant: on a PR, HEAD includes the
# branch, so a bootstrap pin passes; on main after a squash, HEAD == main and
# the orphaned sha is not an ancestor, so it fails. This needs full history —
# the CI job that runs it checks out with fetch-depth: 0.
#
# Exit: 0 if every pin is reachable, 1 if any is missing/unreachable, 2 on a
# usage/environment error.

REPO_PREFIX="${WRANGLE_PINS_REPO:-TomHennen/wrangle}"

repo_root="$(git rev-parse --show-toplevel)" || {
    printf 'check_pin_ancestry: not inside a git work tree\n' >&2
    exit 2
}
workflows_dir="${WRANGLE_WORKFLOWS_DIR:-$repo_root/.github/workflows}"

if [[ ! -d "$workflows_dir" ]]; then
    printf 'check_pin_ancestry: no workflows dir at %s\n' "$workflows_dir" >&2
    exit 2
fi

# Collect the unique 40-hex shas pinned on a TomHennen/wrangle/...@<sha> ref.
# The prefix's '.' is escaped so an org/repo name can't act as a regex wildcard.
escaped_prefix="$(printf '%s' "$REPO_PREFIX" | sed 's/\./\\./g')"
mapfile -t shas < <(
    grep -rhoE "${escaped_prefix}/[^@[:space:]]+@[0-9a-f]{40}" "$workflows_dir" 2>/dev/null \
        | grep -oE '[0-9a-f]{40}$' | sort -u
)

if [[ ${#shas[@]} -eq 0 ]]; then
    printf 'check_pin_ancestry: no %s pins found under %s\n' "$REPO_PREFIX" "$workflows_dir"
    exit 0
fi

rc=0
for sha in "${shas[@]}"; do
    if ! git -C "$repo_root" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        printf 'UNREACHABLE: %s — commit not present (shallow clone? the job needs fetch-depth: 0)\n' "$sha" >&2
        rc=1
        continue
    fi
    if ! git -C "$repo_root" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        printf 'UNREACHABLE: %s — not an ancestor of HEAD (orphaned by a squash merge? re-bump with tools/bump_action_pins.sh <main-sha>)\n' "$sha" >&2
        rc=1
    fi
done

if [[ "$rc" -eq 0 ]]; then
    printf 'check_pin_ancestry: all %d wrangle self-ref pin(s) reachable from HEAD\n' "${#shas[@]}"
fi
exit "$rc"
