#!/bin/bash
set -euo pipefail
set -f

# Fail if any wrangle self-reference pin declared in the working tree resolves to
# a commit that is reachable from the base branch yet NOT on its first-parent
# history — i.e. frozen on a merged side branch — or is so frozen while still
# carrying a non-`main` label. Reachability (check_pin_ancestry) and resolved
# content (check_pin_freshness) both stay green for such a pin: a converge commit
# made on a feature branch and merged as a merge commit is an ancestor of main
# and byte-fresh, but sits on the merge's second-parent line, never on main.
# Finalizing a converge with tools/bump_action_pins.sh <merge-sha> rolls the pins
# onto the first-parent merge commit and relabels them `# main`.
#
# Declared-only, not transitive: after a bump every working-tree pin sits at the
# same sha, so checking the declared pins checks them uniformly. A historical
# tree can nest an older side-branch pin that cannot be rewritten; resolving that
# nested pin is check_pin_ancestry/freshness's concern, not this one.
#
# A pin whose sha is not yet reachable from the base branch is an in-flight
# bootstrap pin (test/integration/SPEC.md) and is left to check_pin_ancestry;
# only merged pins are held to first-parent + `# main`.
#
# Needs the base branch present (CI fetches origin/main; local clones have it).
#
# Exit: 0 all clean, 1 a pin is branch-frozen or mislabeled, 2 usage/environment.

REPO_PREFIX="${WRANGLE_PINS_REPO:-TomHennen/wrangle}"
DEFAULT_BRANCH="${WRANGLE_PINS_DEFAULT_BRANCH:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=self_ref_pin_paths.sh
source "$SCRIPT_DIR/self_ref_pin_paths.sh"

repo_root="$(git rev-parse --show-toplevel)" || {
    printf 'check_pin_main_history: not inside a git work tree\n' >&2
    exit 2
}

# Resolve the base branch, preferring the remote-tracking ref so a stale or
# absent local branch can't misjudge which pins are on main.
base_ref=""
for cand in "${WRANGLE_PINS_MAIN_REF:-}" "origin/$DEFAULT_BRANCH" "$DEFAULT_BRANCH"; do
    [[ -z "$cand" ]] && continue
    if git -C "$repo_root" rev-parse --verify --quiet "$cand^{commit}" >/dev/null; then
        base_ref="$cand"
        break
    fi
done
if [[ -z "$base_ref" ]]; then
    printf 'check_pin_main_history: base branch not found (looked for origin/%s and %s; fetch it first)\n' \
        "$DEFAULT_BRANCH" "$DEFAULT_BRANCH" >&2
    exit 2
fi

mapfile -t pin_paths < <(wrangle_self_ref_pin_paths)
search_dirs=()
for rel in "${pin_paths[@]}"; do
    [[ -d "$repo_root/$rel" ]] && search_dirs+=("$repo_root/$rel")
done
if [[ ${#search_dirs[@]} -eq 0 ]]; then
    printf 'check_pin_main_history: none of the pin paths exist under %s\n' "$repo_root" >&2
    exit 2
fi

# The prefix's '.' is escaped so an org/repo name can't act as a regex wildcard.
escaped_prefix="$(printf '%s' "$REPO_PREFIX" | sed 's/\./\\./g')"
pin_re="${escaped_prefix}/[^@[:space:]]+@[0-9a-f]{40}"

# Match each declared pin together with its optional trailing `# <label>`. YAML
# only, skipping fixtures/, so shell scripts and lint placeholders can't match.
mapfile -t pin_lines < <(
    grep -rhoE --include='*.yml' --include='*.yaml' --exclude-dir=fixtures \
        "${pin_re}([[:space:]]*#[[:space:]]*[^[:space:]]+)?" "${search_dirs[@]}" 2>/dev/null | sort -u
)

if [[ ${#pin_lines[@]} -eq 0 ]]; then
    printf 'check_pin_main_history: no %s pins found in the pin paths\n' "$REPO_PREFIX"
    exit 0
fi

# First-parent commits of the base branch, one sha per line, for O(1) membership.
declare -A first_parent=()
while IFS= read -r fp; do
    first_parent["$fp"]=1
done < <(git -C "$repo_root" rev-list --first-parent "$base_ref")

rc=0
checked=0
declare -A seen=()
for entry in "${pin_lines[@]}"; do
    # Label is the first token after '#' (unanchored, so a trailing date can't
    # be mistaken for it); a pin with no comment leaves the group unset.
    [[ "$entry" =~ @([0-9a-f]{40})([[:space:]]*#[[:space:]]*([^[:space:]]+))? ]] || continue
    sha="${BASH_REMATCH[1]}"
    label="${BASH_REMATCH[3]:-}"
    rest="${entry%@*}"
    subpath="${rest#"$REPO_PREFIX"/}"
    key="$subpath@$sha:$label"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1
    checked=$((checked + 1))

    # In-flight bootstrap pin: not yet on the base branch, so first-parent and
    # label don't apply — check_pin_ancestry covers its HEAD-reachability.
    if ! git -C "$repo_root" merge-base --is-ancestor "$sha" "$base_ref" 2>/dev/null; then
        continue
    fi

    if [[ -z "${first_parent[$sha]:-}" ]]; then
        printf 'BRANCH-FROZEN: %s@%s — merged but not on %s first-parent history (finalize with tools/bump_action_pins.sh <merge-sha>)\n' \
            "$subpath" "${sha:0:9}" "$base_ref" >&2
        rc=1
    elif [[ "$label" != "$DEFAULT_BRANCH" ]]; then
        printf 'MISLABELED: %s@%s — on %s but labeled # %s, not # %s (re-run tools/bump_action_pins.sh <merge-sha>)\n' \
            "$subpath" "${sha:0:9}" "$base_ref" "${label:-<none>}" "$DEFAULT_BRANCH" >&2
        rc=1
    fi
done

if [[ "$rc" -eq 0 ]]; then
    printf 'check_pin_main_history: all %d wrangle self-ref pin(s) on %s first-parent history, labeled # %s\n' \
        "$checked" "$base_ref" "$DEFAULT_BRANCH"
fi
exit "$rc"
