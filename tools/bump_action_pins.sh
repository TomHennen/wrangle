#!/bin/bash
# tools/bump_action_pins.sh — Rewrite TomHennen/wrangle/...@<sha> action refs
# to a target SHA (default: current HEAD). Walks every tree that may carry such
# pins (the shared tools/self_ref_pin_paths.sh set), so nested pins inside
# composites are bumped alongside the workflow pins.
#
# Wrangle's reusable workflows pin to local composite actions via
# fully-qualified SHA refs because GitHub resolves `uses: ./` relative
# to the *caller's* workspace, not the action's own repo. Whenever a
# composite changes, the matching reusable workflow's pin needs a bump
# in the same PR. This script automates the bump.
#
# No per-action change tracking — bump everything to HEAD on each run.
# That matches how `$/` syntax (#136) would behave once it ships.
#
# Idempotency: if every matching pin in a file already points at the
# target SHA, the file is left untouched (the comment date/branch is
# only refreshed when the SHA actually changes). This means running
# the script on different days produces no spurious diff.
#
# Portability: works with GNU and BSD sed. Workflow files are required
# to use LF line endings — CRLF causes the script to error out so the
# rewrite doesn't silently mangle line endings.
#
# Usage:
#   tools/bump_action_pins.sh             # bump every pin to current HEAD
#   tools/bump_action_pins.sh <sha>       # bump every pin to a specific SHA
#
# Env overrides (escape hatch for forks / testing):
#   WRANGLE_PINS_REPO   — repo prefix to match (default: TomHennen/wrangle)
#   WRANGLE_PINS_BRANCH — branch label to write into the comment.
#                         Default detection (in order):
#                           1. If target_sha is reachable from the default
#                              branch (i.e. already merged), use its name. The
#                              remote-tracking ref (`origin/main`) is preferred
#                              over the local branch, which a throwaway worktree
#                              often lacks or leaves stale, so a post-merge
#                              cleanup run on a temporary branch labels correctly.
#                           2. Else use the current branch
#                              (`git symbolic-ref --short HEAD`).
#                           3. Else (detached HEAD) fall back to "main".
#                         WRANGLE_PINS_DEFAULT_BRANCH overrides which branch
#                         the merge-base check considers (default: main).
#   WRANGLE_PINS_DATE   — date label to write into the comment
#                         (default: today's date in YYYY-MM-DD UTC)

set -euo pipefail
set -f

# Resolve the repo to operate on from the current git working directory,
# NOT from the script's own location. This makes the script safe to run
# from any clone (forks, integration tests, ad-hoc checkouts) and keeps
# tests honest — they can target a temporary fixture repo.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    printf 'Error: must be run inside a git working tree\n' >&2
    exit 1
fi

PINS_REPO="${WRANGLE_PINS_REPO:-TomHennen/wrangle}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=self_ref_pin_paths.sh
source "$SCRIPT_DIR/self_ref_pin_paths.sh"

if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [<sha>]\n' "$0" >&2
    exit 1
fi

target_sha="${1:-}"
if [[ -z "$target_sha" ]]; then
    target_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
fi
if [[ ! "$target_sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'Error: target SHA must be a 40-char hex string, got: %s\n' "$target_sha" >&2
    exit 1
fi

default_branch="${WRANGLE_PINS_DEFAULT_BRANCH:-main}"
# Prefer the remote-tracking ref: a throwaway worktree's local default branch is
# often stale or absent, so a target already merged to origin would otherwise
# miss the ancestry test and get mislabeled with the current branch's name.
default_branch_ref=""
for cand in "origin/$default_branch" "$default_branch"; do
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "$cand^{commit}" >/dev/null; then
        default_branch_ref="$cand"
        break
    fi
done
if [[ -n "${WRANGLE_PINS_BRANCH:-}" ]]; then
    branch_label="$WRANGLE_PINS_BRANCH"
elif [[ -n "$default_branch_ref" ]] \
    && git -C "$REPO_ROOT" merge-base --is-ancestor "$target_sha" "$default_branch_ref" >/dev/null 2>&1; then
    # Target is already on the default branch — e.g., the operator branched
    # off main to refresh pins after a merge. Label as the default branch
    # rather than the cleanup branch's name, which would be misleading.
    branch_label="$default_branch"
else
    branch_label="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || printf '%s' "$default_branch")"
fi
date_label="${WRANGLE_PINS_DATE:-$(date -u +%Y-%m-%d)}"

# Build the sed expression. We use | as the delimiter because the matched
# text contains /, which would otherwise need escaping. The `\{0,1\}`
# quantifier is POSIX BRE and works on both GNU and BSD sed (\? is GNU-only).
#
# Anchor: the line must start with optional whitespace and an optional
# YAML list-item dash. Without the anchor, comment lines like
# `# uses: ...@<sha>` would match — wrong, since the comment is supposed
# to neutralize the line.
#
# Trailing comment uses `.*` to match the rest of the line. `.` does not
# match newline in sed (which processes one line at a time by default),
# so `.*` is bounded. Earlier drafts used `[^\r\n]*` to be explicit, but
# BSD sed (macOS) does NOT interpret \r/\n as escape sequences inside a
# bracket expression — it reads them as the literal characters '\', 'r',
# 'n', so any branch name containing those letters (e.g.,
# `claude/implement-npm-build-type-draft`) was truncated at the first
# such letter on macOS, leaving a corrupted trailing comment.
#
# The branch and date labels flow into the sed REPLACEMENT string. Three
# characters need escaping there: `\` (sed escape), `&` (matched-text
# backreference), and `|` (our chosen delimiter — legal in git refs per
# git-check-ref-format(1)). Order matters: backslash first so the others
# don't double-escape. The SHA is `[0-9a-f]{40}` and PINS_REPO is operator-
# supplied (already vetted), so they don't need this treatment.
escape_for_sed_replace() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//|/\\|}"
    printf '%s' "$s"
}
escaped_branch="$(escape_for_sed_replace "$branch_label")"
escaped_date="$(escape_for_sed_replace "$date_label")"

escaped_repo="${PINS_REPO//\//\\/}"
new_suffix="@${target_sha} # ${escaped_branch} ${escaped_date}"

match='\(^[[:space:]]*-\{0,1\}[[:space:]]*uses:[[:space:]]*'"$escaped_repo"'/[^@[:space:]]*\)@[0-9a-f]\{40\}\([[:space:]]*#.*\)\{0,1\}'
replace='\1'"$new_suffix"

# Resolve the pin-path set against this clone, skipping trees it lacks.
mapfile -t pin_paths < <(wrangle_self_ref_pin_paths)
search_dirs=()
for rel in "${pin_paths[@]}"; do
    [[ -d "$REPO_ROOT/$rel" ]] && search_dirs+=("$REPO_ROOT/$rel")
done

# Expand the YAML glob inside a subshell so the `set +f` toggle is
# unconditionally scoped — even if collection fails, the parent stays noglob.
# `globstar` recurses so nested composite action.yml files are found, not only
# the flat workflows dir. fixtures/ subtrees are skipped so a lint fixture's
# placeholder pin can't be rewritten. Files then iterate in the parent with
# `set -f` on.
files=()
while IFS= read -r f; do
    files+=("$f")
done < <(
    set +f
    shopt -s nullglob globstar
    for base in "${search_dirs[@]}"; do
        for g in "$base"/**/*.yml "$base"/**/*.yaml; do
            [[ -f "$g" && "$g" != */fixtures/* ]] && printf '%s\n' "$g"
        done
    done
)

# Write to a sibling tempfile (same filesystem as the source) and atomic-mv
# — $TMPDIR is often a different mount where `mv` falls back to copy+unlink.
tmp_file=""
# shellcheck disable=SC2317 # invoked indirectly via trap
cleanup_tmp() {
    [[ -n "$tmp_file" && -f "$tmp_file" ]] && rm -f "$tmp_file"
    tmp_file=""
}
trap cleanup_tmp EXIT INT TERM

changed=0
total=0
for f in "${files[@]}"; do
    # Filter to files that even contain a matching pin.
    if ! grep -q -E "uses:[[:space:]]*${PINS_REPO}/[^@[:space:]]+@[0-9a-f]{40}" "$f"; then
        continue
    fi
    total=$((total + 1))

    # Reject CRLF — silently dropping \r would produce mixed line endings.
    if grep -q $'\r' "$f"; then
        # shellcheck disable=SC2016 # the backticks are part of the human-readable message, not an attempt at command substitution
        printf 'Error: %s has CRLF line endings; convert to LF first (see dos2unix(1) or `tr -d "\\r" < file > tmp && mv tmp file`).\n' "${f#"$REPO_ROOT"/}" >&2
        exit 1
    fi

    # Idempotency: if every existing pin already matches the target SHA,
    # leave the file alone (preserves the existing comment, so re-runs
    # on different days don't produce spurious diffs).
    needs_update=false
    while IFS= read -r existing_sha; do
        if [[ "$existing_sha" != "$target_sha" ]]; then
            needs_update=true
            break
        fi
    done < <(grep -oE "${PINS_REPO}/[^@[:space:]]+@[0-9a-f]{40}" "$f" | grep -oE '[0-9a-f]{40}$')
    if [[ "$needs_update" == "false" ]]; then
        continue
    fi

    tmp_file="$(mktemp "$f.XXXXXX")"
    sed "s|$match|$replace|g" "$f" > "$tmp_file"
    mv "$tmp_file" "$f"
    tmp_file=""
    changed=$((changed + 1))
    printf 'bumped: %s\n' "${f#"$REPO_ROOT"/}"
done

printf '\nSummary: %d file(s) had pins, %d file(s) changed.\n' "$total" "$changed"
printf 'Target SHA: %s\n' "$target_sha"
printf 'Comment:    # %s %s\n' "$branch_label" "$date_label"
