#!/bin/bash
set -euo pipefail
set -f

# tools/open_catalog_bump_pr.sh — open (or refresh) the catalog auto-bump PR.
#
# Runs after bump_catalog_to_latest.sh in the post-publish workflow: it takes the
# already-modified tools/catalog.json in the working tree, commits it to a
# dedicated bot branch, converges the self-ref pins onto that commit, and opens a
# PR (or force-updates the existing one, so a rolling publish keeps a single PR
# rather than piling up). No-op when the catalog is unchanged. First-party
# rebuilds are cooldown-exempt (§11), so the PR is meant to be reviewed and merged
# on CI/review latency, not held for the 7-day community-vetting delay. Uses git +
# the gh CLI with the ambient GITHUB_TOKEN.
#
# The convergence step is required: check_pin_freshness folds tools/catalog.json
# into every pin's scope, so a catalog-only commit stales the consumers until the
# pins are re-bumped onto it.
#
# Setup requirement: the repository must have "Allow GitHub Actions to create and
# approve pull requests" enabled, or `gh pr create` with GITHUB_TOKEN fails.
#
# Exit: 0 PR opened/updated, or nothing to do; 2 git/gh failure.

BRANCH="${WRANGLE_AUTOBUMP_BRANCH:-bot/catalog-autobump}"
REMOTE="${WRANGLE_AUTOBUMP_REMOTE:-origin}"
BASE="${WRANGLE_AUTOBUMP_BASE:-main}"
CATALOG_REL="tools/catalog.json"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pr_title() {
    printf 'chore(catalog): bump curated tool-image digests to :latest'
}

pr_body() {
    cat <<'BODY'
Automated by the post-publish auto-bump (docs/tool_container_design.md §11).

`local_publish_images.yml` republished wrangle's curated tool images, so their
`:latest` digests moved ahead of the pins in `tools/catalog.json`. This PR
repoints each drifted first-party entry to the digest just published.

**First-party, cooldown-exempt.** These are rebuilds of wrangle's own reviewed
source under `ghcr.io/tomhennen/wrangle/*`, not third-party updates — the 7-day
community-vetting cooldown does not apply. Review the digests and merge on
CI/review latency to keep the catalog current.

Adopter-override entries (a foreign namespace) are never touched here; those
pins stay adopter-owned.

**Merge as a merge commit, not a squash.** Beyond the catalog bump this PR carries
self-ref pin-convergence commits (one per nesting level); squashing re-orphans the
intermediate pins. The `# <branch>` pin labels are relabelled `# main` at release.

Refs #619, #596.
BODY
}

# push_branch — force-with-lease $BRANCH to $REMOTE. The lease is an explicit
# expected value from ls-remote (empty when the branch is new), so it works for
# both the first push and a rolling update without a remote-tracking ref. When
# GH_TOKEN is set on an https remote (the CI path, run with
# persist-credentials: false), auth is an http.extraheader carried in the
# environment, never in argv or on-disk config.
push_branch() {
    local -a auth=()
    if [[ -n "${GH_TOKEN:-}" && "$(git remote get-url "$REMOTE")" == https://* ]]; then
        local hdr
        hdr="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
        auth=(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader "GIT_CONFIG_VALUE_0=Authorization: Basic ${hdr}")
    fi
    local expected
    expected="$("${auth[@]}" git ls-remote "$REMOTE" "refs/heads/$BRANCH" | cut -f1)" || return 1
    "${auth[@]}" git push --force-with-lease="refs/heads/$BRANCH:${expected}" "$REMOTE" "$BRANCH"
}

# open_or_update_pr — open a PR from $BRANCH, or leave the existing open one (the
# force-push already refreshed it). Returns non-zero on a gh failure.
open_or_update_pr() {
    local existing
    existing="$(gh pr list --repo "$WRANGLE_AUTOBUMP_GH_REPO" --head "$BRANCH" --base "$BASE" --state open --json number --jq 'length')" || return 1
    if [[ "$existing" != "0" ]]; then
        printf 'open_catalog_bump_pr: PR from %s already open; force-push refreshed it\n' "$BRANCH"
        return 0
    fi
    gh pr create --repo "$WRANGLE_AUTOBUMP_GH_REPO" \
        --base "$BASE" --head "$BRANCH" \
        --title "$(pr_title)" --body "$(pr_body)"
}

main() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)" || return 2
    cd "$repo_root" || return 2

    if git diff --quiet -- "$CATALOG_REL"; then
        printf 'open_catalog_bump_pr: catalog unchanged; nothing to open\n'
        return 0
    fi
    : "${WRANGLE_AUTOBUMP_GH_REPO:?set WRANGLE_AUTOBUMP_GH_REPO (owner/repo)}"

    # Set the bot identity at repo scope: the catalog commit and every
    # converge_action_pins.sh pin commit (which commits with no inline identity)
    # both need it, and the CI checkout configures none.
    git config user.name "$BOT_NAME"
    git config user.email "$BOT_EMAIL"

    git switch -C "$BRANCH" >/dev/null 2>&1 || { printf 'open_catalog_bump_pr: could not create branch %s\n' "$BRANCH" >&2; return 2; }
    git add "$CATALOG_REL"
    git commit -m "$(pr_title)" >/dev/null || { printf 'open_catalog_bump_pr: commit failed\n' >&2; return 2; }
    # The catalog commit stales every pin (freshness folds tools/catalog.json into
    # each pin's scope); converge re-bumps them onto it so the PR passes freshness.
    "$SCRIPT_DIR/converge_action_pins.sh" || { printf 'open_catalog_bump_pr: pin convergence failed\n' >&2; return 2; }
    push_branch || { printf 'open_catalog_bump_pr: push failed\n' >&2; return 2; }
    open_or_update_pr || { printf 'open_catalog_bump_pr: gh pr open failed\n' >&2; return 2; }
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
