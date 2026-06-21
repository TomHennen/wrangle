#!/bin/bash
set -euo pipefail
set -f

# Fail if any wrangle self-reference pin resolves to STALE action code — i.e. the
# pinned sha's tree for that path differs from HEAD's tree in something other than
# the SHAs of the self-ref pins nested inside it. A pin can be reachable (an
# ancestor of HEAD, so check_pin_ancestry is green) yet still resolve OLD code if
# the path's scripts/logic changed after the pin was last bumped; the
# showcase/integration then silently runs the stale action.
#
# Freshness is RESOLVED-content, not byte-identity of the tree: a converged
# nested chain pins each composite at an OLDER sha whose own nested-pin SHAs
# differ from HEAD's (each converge cycle re-bumps them), so a raw tree diff
# would false-positive forever. So a path is fresh when its tree differs from
# HEAD ONLY on self-ref `uses:` pin lines, AND every nested pin is itself fresh
# (checked transitively by the BFS). Any non-pin change — e.g. #558's
# run_verify.sh, while verify/action.yml stayed byte-identical — is STALE.
#
# Needs full history (CI runs it with fetch-depth: 0). Reachability is
# check_pin_ancestry's job; both are required.
#
# Exit: 0 all fresh, 1 a pin is stale/missing, 2 usage/environment error.

REPO_PREFIX="${WRANGLE_PINS_REPO:-TomHennen/wrangle}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=self_ref_pin_paths.sh
source "$SCRIPT_DIR/self_ref_pin_paths.sh"

repo_root="$(git rev-parse --show-toplevel)" || {
    printf 'check_pin_freshness: not inside a git work tree\n' >&2
    exit 2
}

mapfile -t pin_paths < <(wrangle_self_ref_pin_paths)
search_dirs=()
for rel in "${pin_paths[@]}"; do
    [[ -d "$repo_root/$rel" ]] && search_dirs+=("$repo_root/$rel")
done
if [[ ${#search_dirs[@]} -eq 0 ]]; then
    printf 'check_pin_freshness: none of the pin paths exist under %s\n' "$repo_root" >&2
    exit 2
fi

# The prefix's '.' is escaped so an org/repo name can't act as a regex wildcard.
escaped_prefix="$(printf '%s' "$REPO_PREFIX" | sed 's/\./\\./g')"
pin_re="${escaped_prefix}/[^@[:space:]]+@[0-9a-f]{40}"

# path_content_stale <sha> <subpath> — true (0) iff <subpath>'s tree at <sha>
# differs from HEAD's in a line that is NOT a self-ref pin reference. Pin-SHA-only
# differences are ignored here; each nested pin's own freshness is checked as the
# BFS descends. -G/-S can't express "only these lines changed", so we diff with
# no context and scan the +/- body lines.
path_content_stale() {
    local sha="$1" subpath="$2" line
    while IFS= read -r line; do
        # Skip diff headers (+++/---) and hunk markers; inspect only body changes.
        case "$line" in
            '+++ '* | '--- '* | '@@'*) continue ;;
            '+'* | '-'*) ;;
            *) continue ;;
        esac
        # A changed line that isn't a self-ref pin reference = real content drift.
        if ! printf '%s' "${line:1}" | grep -qE "$pin_re"; then
            return 0
        fi
    done < <(git -C "$repo_root" diff --unified=0 "$sha" HEAD -- "$subpath" 2>/dev/null)
    return 1
}

# Seed from pins declared in the working tree. YAML only, skipping fixtures/, so
# shell scripts and lint placeholders can't false-match.
mapfile -t root_refs < <(
    grep -rhoE --include='*.yml' --include='*.yaml' --exclude-dir=fixtures \
        "$pin_re" "${search_dirs[@]}" 2>/dev/null | sort -u
)

if [[ ${#root_refs[@]} -eq 0 ]]; then
    printf 'check_pin_freshness: no %s pins found in the pin paths\n' "$REPO_PREFIX"
    exit 0
fi

# BFS; <via> carries the parent so a stale nested pin names its source.
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
        printf 'MISSING: %s@%s — commit not present (shallow clone? the job needs fetch-depth: 0) [via %s]\n' \
            "$subpath" "$sha" "$via" >&2
        rc=1
        continue
    fi

    # Stale = the pinned tree for this path differs from HEAD in any line that is
    # NOT a self-ref pin SHA. Self-ref pin lines are excluded because a converged
    # chain legitimately pins composites at older shas whose nested pin SHAs
    # differ; those nested pins' freshness is verified separately as the BFS
    # descends into them. Whole-path diff so a change to any script under the
    # action dir is caught, not just action.yml.
    if path_content_stale "$sha" "$subpath"; then
        printf 'STALE: %s@%s — resolves non-pin content that differs from HEAD (re-bump with tools/converge_action_pins.sh) [via %s]\n' \
            "$subpath" "${sha:0:9}" "$via" >&2
        rc=1
        # Still walk it: surfacing every stale hop in one run beats one-at-a-time.
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
    printf 'check_pin_freshness: all %d wrangle self-ref pin(s) resolve to HEAD content\n' "$checked"
fi
exit "$rc"
