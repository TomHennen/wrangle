#!/usr/bin/env bash
set -euo pipefail

# Push a tracking tag to the companion repo so its showcase.yml runs
# against the current state of wrangle's main. The tag name encodes
# the date and wrangle's commit SHA so each main commit gets its own
# tag, and reruns of the same commit are idempotent.
#
# Usage: push_showcase_tag.sh <wrangle_sha>
#
# Environment:
#   GH_TOKEN          PAT with contents:write on the companion repo
#   COMPANION_REPO    Owner/repo of the companion (default: tomhennen/wrangle-test)
#
# Exit codes:
#   0  Tag created OR tag already exists for this SHA (idempotent rerun)
#   1  Companion repo unreachable, or tag creation failed
#   2  Bad usage / missing environment

WRANGLE_SHA="${1:?Usage: push_showcase_tag.sh <wrangle_sha>}"

if [[ -z "${GH_TOKEN:-}" ]]; then
    printf 'ERROR: GH_TOKEN not set (need contents:write on companion repo)\n' >&2
    exit 2
fi

COMPANION_REPO="${COMPANION_REPO:-tomhennen/wrangle-test}"

# Tag shape: vYYYYMMDD-<7-char-sha>. Triggers wrangle-test's showcase.yml
# (subscribed to `v*`); wrangle-test treats anything that isn't pure
# semver as a tracking tag and marks the resulting Release as a
# pre-release.
SHORT_SHA="${WRANGLE_SHA:0:7}"
DATE="$(date -u +%Y%m%d)"
TAG="v${DATE}-${SHORT_SHA}"

# Idempotent on rerun: if the tag already exists, the showcase has
# already been triggered for this main HEAD — nothing to do.
if gh api "repos/${COMPANION_REPO}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
    printf 'Tag %s already exists on %s; nothing to do\n' "$TAG" "$COMPANION_REPO"
    exit 0
fi

# Point the tag at the companion repo's current main HEAD. The tag
# triggers showcase.yml, which runs the wrangle-test fixtures (their
# current state, not wrangle's) through wrangle's reusable workflows.
TARGET_SHA="$(gh api "repos/${COMPANION_REPO}/git/ref/heads/main" --jq .object.sha)"
if [[ -z "$TARGET_SHA" ]]; then
    printf 'ERROR: Could not resolve %s main HEAD\n' "$COMPANION_REPO" >&2
    exit 1
fi

printf 'Creating tag %s -> %s on %s\n' "$TAG" "$TARGET_SHA" "$COMPANION_REPO"

# gh api emits the created ref JSON on success; route to /dev/null to
# avoid leaking it into logs.
gh api "repos/${COMPANION_REPO}/git/refs" \
    --method POST \
    --field "ref=refs/tags/${TAG}" \
    --field "sha=${TARGET_SHA}" >/dev/null

printf 'Pushed %s — showcase.yml will run on %s\n' "$TAG" "$COMPANION_REPO"
