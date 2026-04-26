#!/bin/bash
# tools/bump_action_pins.sh — Rewrite TomHennen/wrangle/...@<sha> action refs
# in .github/workflows/ to a target SHA (default: current HEAD).
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
# Usage:
#   tools/bump_action_pins.sh             # bump every pin to current HEAD
#   tools/bump_action_pins.sh <sha>       # bump every pin to a specific SHA
#
# Env overrides (escape hatch for forks / testing):
#   WRANGLE_PINS_REPO   — repo prefix to match (default: TomHennen/wrangle)
#   WRANGLE_PINS_DIR    — directory to walk (default: .github/workflows)
#   WRANGLE_PINS_BRANCH — branch label to write into the comment
#                         (default: `git symbolic-ref --short HEAD`,
#                         falling back to "main" if detached)
#   WRANGLE_PINS_DATE   — date label to write into the comment
#                         (default: today's date in YYYY-MM-DD UTC)

set -euo pipefail

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
PINS_DIR="${WRANGLE_PINS_DIR:-.github/workflows}"

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

if [[ -n "${WRANGLE_PINS_BRANCH:-}" ]]; then
    branch_label="$WRANGLE_PINS_BRANCH"
else
    branch_label="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo main)"
fi
date_label="${WRANGLE_PINS_DATE:-$(date -u +%Y-%m-%d)}"

# Build the sed expression. Escape the slashes in the repo prefix so
# they survive the s|||g delimiter choice. We use | as the delimiter
# because the matched text contains /, which would otherwise need
# escaping.
escaped_repo="${PINS_REPO//\//\\/}"
new_suffix="@${target_sha} # ${branch_label} ${date_label}"

# Match group 1: the path between the repo prefix and the @ separator.
# The whole tail (sha + optional " # ..." comment) is replaced.
match='\(uses:[[:space:]]*'"$escaped_repo"'/[^@[:space:]]*\)@[0-9a-f]\{40\}\([[:space:]]*#[^\n]*\)\?'
replace='\1'"$new_suffix"

# Walk every YAML file in the target dir and rewrite in place. POSIX sed
# (BSD on macOS, GNU on Linux) differ on -i; sed's -i'' form works on GNU
# but not BSD. To stay portable, write to a temp file and atomically replace.
shopt -s nullglob
changed=0
total=0
for f in "$REPO_ROOT/$PINS_DIR"/*.yml "$REPO_ROOT/$PINS_DIR"/*.yaml; do
    [[ -f "$f" ]] || continue
    if ! grep -q -E "uses:[[:space:]]*${PINS_REPO}/[^@[:space:]]+@[0-9a-f]{40}" "$f"; then
        continue
    fi
    total=$((total + 1))
    tmp="$(mktemp)"
    sed "s|$match|$replace|g" "$f" > "$tmp"
    if ! cmp -s "$f" "$tmp"; then
        mv "$tmp" "$f"
        changed=$((changed + 1))
        printf 'bumped: %s\n' "${f#"$REPO_ROOT"/}"
    else
        rm -f "$tmp"
    fi
done

printf '\nSummary: %d file(s) had pins, %d file(s) changed.\n' "$total" "$changed"
printf 'Target SHA: %s\n' "$target_sha"
printf 'Comment:    # %s %s\n' "$branch_label" "$date_label"
