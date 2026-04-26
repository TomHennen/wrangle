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

# Build the sed expression. We use | as the delimiter because the matched
# text contains /, which would otherwise need escaping. The `\{0,1\}`
# quantifier is POSIX BRE and works on both GNU and BSD sed (\? is GNU-only).
#
# Anchor: the line must start with optional whitespace and an optional
# YAML list-item dash. Without the anchor, comment lines like
# `# uses: ...@<sha>` would match — wrong, since the comment is supposed
# to neutralize the line.
escaped_repo="${PINS_REPO//\//\\/}"
new_suffix="@${target_sha} # ${branch_label} ${date_label}"

match='\(^[[:space:]]*-\{0,1\}[[:space:]]*uses:[[:space:]]*'"$escaped_repo"'/[^@[:space:]]*\)@[0-9a-f]\{40\}\([[:space:]]*#[^\r\n]*\)\{0,1\}'
replace='\1'"$new_suffix"

# Walk every YAML file in the target dir and rewrite in place. We write
# to a sibling temp file (mktemp on the same filesystem) and atomically
# rename — `mktemp` defaults to $TMPDIR, often a different mount, where
# `mv` falls back to copy+unlink (not atomic).
tmp_file=""
cleanup() { [[ -n "$tmp_file" && -f "$tmp_file" ]] && rm -f "$tmp_file"; tmp_file=""; }
trap cleanup EXIT INT TERM

shopt -s nullglob
changed=0
total=0
for f in "$REPO_ROOT/$PINS_DIR"/*.yml "$REPO_ROOT/$PINS_DIR"/*.yaml; do
    [[ -f "$f" ]] || continue

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
