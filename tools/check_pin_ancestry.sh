#!/bin/bash
set -euo pipefail
set -f

# Fail if any wrangle self-reference pin resolves to a sha not reachable from
# HEAD. Transitive: each pin is resolved at its pinned sha (git show <sha>:<path>)
# and the pins nested in that action.yml are walked too, so a chain like
# workflow -> verify_release -> verify holds at every hop. A working-tree-only
# check false-greens after one re-bump of such a chain; a nested sha whose commit
# is absent fails closed. Needs full history (CI runs it with fetch-depth: 0).
# Bootstrap-pin lifecycle and re-bump recovery: docs/e2e_testing.md.
#
# Exit: 0 all reachable, 1 missing/unreachable, 2 usage/environment error.

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

# Seed from pins declared in the working tree. YAML only, skipping fixtures/, so
# shell scripts and lint placeholders can't false-match.
mapfile -t root_refs < <(
    grep -rhoE --include='*.yml' --include='*.yaml' --exclude-dir=fixtures \
        "$pin_re" "${search_dirs[@]}" 2>/dev/null | sort -u
)

if [[ ${#root_refs[@]} -eq 0 ]]; then
    printf 'check_pin_ancestry: no %s pins found in the pin paths\n' "$REPO_PREFIX"
    exit 0
fi

# BFS; <via> carries the parent so an unreachable nested pin names its source.
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

    # Resolve the action at its pinned sha and walk the pins nested inside it.
    # No action.yml at that sha = leaf (the ref may be a reusable workflow).
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
