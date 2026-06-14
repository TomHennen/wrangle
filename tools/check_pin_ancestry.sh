#!/bin/bash
set -euo pipefail
set -f

# tools/check_pin_ancestry.sh — fail if any wrangle self-reference action pin
# is not reachable from HEAD. Walks every tree that may carry such pins (the
# shared tools/self_ref_pin_paths.sh set), not just .github/workflows, so a
# nested pin in a composite is held to the same reachability invariant.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=self_ref_pin_paths.sh
source "$SCRIPT_DIR/self_ref_pin_paths.sh"

repo_root="$(git rev-parse --show-toplevel)" || {
    printf 'check_pin_ancestry: not inside a git work tree\n' >&2
    exit 2
}

mapfile -t pin_paths < <(wrangle_self_ref_pin_paths)
search_dirs=()
for rel in "${pin_paths[@]}"; do
    [[ -d "$repo_root/$rel" ]] && search_dirs+=("$repo_root/$rel")
done
if [[ ${#search_dirs[@]} -eq 0 ]]; then
    printf 'check_pin_ancestry: none of the pin paths exist under %s\n' "$repo_root" >&2
    exit 2
fi

# Collect the unique 40-hex shas pinned on a TomHennen/wrangle/...@<sha> ref.
# Restricted to YAML and skipping fixtures/ so action/workflow files are
# searched but shell scripts, SPEC.md, and lint fixtures (which carry
# placeholder shas) can't false-match.
# The prefix's '.' is escaped so an org/repo name can't act as a regex wildcard.
escaped_prefix="$(printf '%s' "$REPO_PREFIX" | sed 's/\./\\./g')"
mapfile -t shas < <(
    grep -rhoE --include='*.yml' --include='*.yaml' --exclude-dir=fixtures \
        "${escaped_prefix}/[^@[:space:]]+@[0-9a-f]{40}" "${search_dirs[@]}" 2>/dev/null \
        | grep -oE '[0-9a-f]{40}$' | sort -u
)

if [[ ${#shas[@]} -eq 0 ]]; then
    printf 'check_pin_ancestry: no %s pins found in the pin paths\n' "$REPO_PREFIX"
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
