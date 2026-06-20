#!/bin/bash
set -euo pipefail
set -f

# tools/check_pin_ancestry.sh — fail if any wrangle self-reference action pin
# resolves to a sha that is not reachable from HEAD. The walk is transitive:
# every declared pin is resolved AT its pinned sha (git show <sha>:<path>) and
# the self-ref pins nested inside that resolved action.yml are walked too, so a
# 2-level chain (workflow -> verify_release -> verify, or scan -> tools/*) is
# held to the invariant at every hop.
#
# Why transitive: a literal-pin-only check reads the action.yml in the working
# tree, but what actually runs on main is the action.yml AS OF the pinned sha.
# After a single post-merge re-bump the two diverge — the workflow's
# verify_release@<merge> still resolves a verify_release/action.yml that nests
# the orphaned verify@<branch>, even though the working-tree copy already nests
# the fixed verify@<merge>. A literal check goes green there (false green) while
# the release path resolves stale code; the transitive walk catches it.
#
# Why reachable-from-HEAD: a "bootstrap pin" (see test/integration/SPEC.md
# §Known limitations) points a self-reference at a BRANCH sha so the integration
# test can exercise a not-yet-merged change. On a PR, HEAD includes the branch,
# so the pin passes; a SQUASH merge orphans the branch sha, after which HEAD ==
# main no longer reaches it and this check goes red, forcing the re-bump
# (tools/bump_action_pins.sh <main-sha>). This needs full history — the CI job
# checks out with fetch-depth: 0.
#
# A nested sha whose commit object is absent fails closed (UNREACHABLE), never
# silently skipped.
#
# Exit: 0 if every resolved pin is reachable, 1 if any is missing/unreachable,
# 2 on a usage/environment error.

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

# The prefix's '.' is escaped so an org/repo name can't act as a regex wildcard.
escaped_prefix="$(printf '%s' "$REPO_PREFIX" | sed 's/\./\\./g')"
pin_re="${escaped_prefix}/[^@[:space:]]+@[0-9a-f]{40}"

# Seed the walk with the pins declared in the working tree. Restricted to YAML
# and skipping fixtures/ so action/workflow files are searched but shell
# scripts, SPEC.md, and lint fixtures (which carry placeholder shas) can't
# false-match.
mapfile -t root_refs < <(
    grep -rhoE --include='*.yml' --include='*.yaml' --exclude-dir=fixtures \
        "$pin_re" "${search_dirs[@]}" 2>/dev/null | sort -u
)

if [[ ${#root_refs[@]} -eq 0 ]]; then
    printf 'check_pin_ancestry: no %s pins found in the pin paths\n' "$REPO_PREFIX"
    exit 0
fi

# BFS over "<via>|<ref>" entries; <via> is the human-readable resolution context
# so an unreachable nested pin names the parent that pulled it in.
declare -A visited=()
queue=()
for ref in "${root_refs[@]}"; do
    queue+=("declared|$ref")
done

rc=0
checked=0
while [[ ${#queue[@]} -gt 0 ]]; do
    via="${queue[0]%%|*}"
    ref="${queue[0]#*|}"
    queue=("${queue[@]:1}")

    rest="${ref#"$REPO_PREFIX"/}"
    subpath="${rest%@*}"
    sha="${rest##*@}"
    key="$subpath@$sha"
    [[ -n "${visited[$key]:-}" ]] && continue
    visited[$key]=1
    checked=$((checked + 1))

    if ! git -C "$repo_root" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        printf 'UNREACHABLE: %s@%s — commit not present (shallow clone? the job needs fetch-depth: 0) [via %s]\n' \
            "$subpath" "$sha" "$via" >&2
        rc=1
        continue
    fi
    if ! git -C "$repo_root" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        printf 'UNREACHABLE: %s@%s — not an ancestor of HEAD (orphaned by a squash merge? re-bump with tools/bump_action_pins.sh <main-sha>) [via %s]\n' \
            "$subpath" "$sha" "$via" >&2
        rc=1
        continue
    fi

    # Resolve the action AT its pinned sha and enqueue the self-ref pins nested
    # inside it. A subpath with no action.yml at that sha is a leaf (the ref may
    # name a reusable workflow, not a composite) — nothing further to walk.
    content="$(git -C "$repo_root" show "$sha:$subpath/action.yml" 2>/dev/null)" \
        || content="$(git -C "$repo_root" show "$sha:$subpath/action.yaml" 2>/dev/null)" \
        || content=""
    [[ -z "$content" ]] && continue
    while IFS= read -r nested; do
        [[ -n "$nested" ]] && queue+=("${subpath}@${sha:0:9}|$nested")
    done < <(printf '%s\n' "$content" | grep -hoE "$pin_re" | sort -u)
done

if [[ "$rc" -eq 0 ]]; then
    printf 'check_pin_ancestry: all %d wrangle self-ref pin(s) reachable from HEAD\n' "$checked"
fi
exit "$rc"
