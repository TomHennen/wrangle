#!/bin/bash
set -euo pipefail
set -f

# tools/open_catalog_bump_pr.sh — open (or refresh) the catalog auto-bump PR.
#
# Runs after bump_catalog_to_latest.sh in the post-publish workflow: it takes the
# already-modified tools/catalog.json in the working tree, commits it to a
# dedicated bot branch, and opens a PR (or force-updates the existing one, so a
# rolling publish keeps a single PR rather than piling up). No-op when the catalog
# is unchanged. First-party rebuilds are cooldown-exempt (§11), so the PR is
# meant to be reviewed and merged on CI/review latency, not held for the 7-day
# community-vetting delay. Uses git + the gh CLI with the ambient GITHUB_TOKEN.
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

pr_title() {
    printf 'chore(catalog): bump curated tool-image digests to :latest'
}

# pr_body — the PR description. States the first-party cooldown exemption and the
# required repository setting; links the design and issues.
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

Refs #619, #596.
BODY
}

# push_branch — force-push $BRANCH to $REMOTE. When GH_TOKEN is set and the
# remote is https (the CI path, run with persist-credentials: false), it pushes
# to a token-authenticated URL so no credential is persisted on disk; a local
# remote (the test path) pushes as-is.
push_branch() {
    local target="$REMOTE" url
    if [[ -n "${GH_TOKEN:-}" ]]; then
        url="$(git remote get-url "$REMOTE")"
        [[ "$url" == https://* ]] && target="https://x-access-token:${GH_TOKEN}@${url#https://}"
    fi
    git push --force "$target" "$BRANCH"
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

    git switch -C "$BRANCH" >/dev/null 2>&1 || { printf 'open_catalog_bump_pr: could not create branch %s\n' "$BRANCH" >&2; return 2; }
    git add "$CATALOG_REL"
    git -c "user.name=$BOT_NAME" -c "user.email=$BOT_EMAIL" \
        commit -m "$(pr_title)" >/dev/null || { printf 'open_catalog_bump_pr: commit failed\n' >&2; return 2; }
    push_branch || { printf 'open_catalog_bump_pr: push failed\n' >&2; return 2; }
    open_or_update_pr || { printf 'open_catalog_bump_pr: gh pr open failed\n' >&2; return 2; }
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
