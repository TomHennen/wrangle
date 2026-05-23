#!/usr/bin/env bash
set -euo pipefail
set -f  # disable globbing — processes external input (positional SHA arg)

# Push a tracking tag to the companion repo so its showcase.yml runs
# end-to-end against the current state of wrangle's main.
#
# Tag shape: vYYYYMMDD-<7-char-wrangle-sha>. The date is the commit's
# committer date (NOT wall-clock) so reruns of the same commit produce
# the same tag regardless of when they happen. The companion repo's
# showcase.yml treats anything that isn't pure semver as a tracking
# tag and marks the resulting Release as a pre-release.
#
# Skip semantics: the script is a no-op when either
#   (a) the tag already exists on the companion (literal idempotency), or
#   (b) the most recent tracking tag points at a wrangle commit identical
#       to HEAD by `git diff` (no adopter-visible change since the last
#       run; the showcase would produce identical output).
# Together these implement the gating contract: "if any wrangle source
# changed since the last showcase run, refresh it." The caller workflow
# carries no paths: filter — gating happens here so it stays correct
# even when new adopter-facing surface is added.
#
# Naming asymmetry (documented loudly): the tag NAME embeds the wrangle
# SHA, but the resulting showcase RUN exercises whatever
# tomhennen/wrangle-test main is at the moment the tag fires. If
# wrangle-test main moves between two wrangle pushes, two consecutive
# tracking tags name two wrangle SHAs but reflect *different*
# wrangle-test states. This is intentional: the showcase is a
# current-state heartbeat, not a reproducibility artifact. See
# docs/RELEASING.md.
#
# Usage: push_showcase_tag.sh <wrangle_sha>
#
# Environment:
#   GH_TOKEN          PAT with contents:write on the companion repo
#   COMPANION_REPO    Owner/repo of the companion (default: tomhennen/wrangle-test)
#
# Exit codes:
#   0  Tag created OR skip condition hit (idempotent rerun, or no diff)
#   1  Companion repo unreachable, or tag creation failed, or local git error
#   2  Bad usage / missing environment

WRANGLE_SHA="${1:?Usage: push_showcase_tag.sh <wrangle_sha>}"

# Reject anything that isn't a full 40-char hex SHA. github.sha is
# always full; truncating to 7 chars below assumes the input is sound.
if [[ ! "$WRANGLE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'ERROR: WRANGLE_SHA must be a full 40-char hex SHA (got %q)\n' "$WRANGLE_SHA" >&2
    exit 2
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
    printf 'ERROR: GH_TOKEN not set (need contents:write on companion repo)\n' >&2
    exit 2
fi

COMPANION_REPO="${COMPANION_REPO:-tomhennen/wrangle-test}"

# Committer date from the commit itself — deterministic regardless of
# when the workflow runs. Requires the workflow to checkout with enough
# depth to see WRANGLE_SHA (fetch-depth: 0 in the caller).
if ! COMMIT_DATE="$(git log -1 --format=%cd --date=format:%Y%m%d "$WRANGLE_SHA" 2>/dev/null)"; then
    printf 'ERROR: could not resolve commit date for %s; is fetch-depth sufficient?\n' "$WRANGLE_SHA" >&2
    exit 1
fi
if [[ ! "$COMMIT_DATE" =~ ^[0-9]{8}$ ]]; then
    printf 'ERROR: unexpected commit date format: %q\n' "$COMMIT_DATE" >&2
    exit 1
fi

SHORT_SHA="${WRANGLE_SHA:0:7}"
TAG="v${COMMIT_DATE}-${SHORT_SHA}"

# (a) Literal idempotency: tag already exists for this commit.
if gh api "repos/${COMPANION_REPO}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
    printf 'Tag %s already exists on %s; nothing to do\n' "$TAG" "$COMPANION_REPO"
    exit 0
fi

# (b) Runtime diff: if there's a previous tracking tag and HEAD is
# identical to its embedded wrangle SHA by `git diff`, skip. The
# contract is "if any wrangle source moved since the last tracking
# tag, refresh the showcase" — gating computed against the actual
# tree, with no hand-maintained path list to drift.
LATEST_TRACKING_TAG=""
LATEST_TRACKING_SHA=""
if MATCHING_TAGS_JSON="$(gh api "repos/${COMPANION_REPO}/git/matching-refs/tags/v" 2>/dev/null)"; then
    # Filter to vYYYYMMDD-<7hex>, sort lexically (date sorts correctly
    # as YYYYMMDD), take the last one.
    LATEST_TRACKING_TAG="$(printf '%s' "$MATCHING_TAGS_JSON" \
        | jq -r '[.[] | .ref | sub("^refs/tags/"; "")
            | select(test("^v[0-9]{8}-[0-9a-f]{7}$"))] | sort | last // ""')"
fi

if [[ -n "$LATEST_TRACKING_TAG" ]]; then
    # Extract the wrangle SHA suffix from the tag name (last 7 chars).
    LATEST_TRACKING_SHA="${LATEST_TRACKING_TAG##*-}"
    if git rev-parse --verify "${LATEST_TRACKING_SHA}^{commit}" >/dev/null 2>&1; then
        if git diff --quiet "$LATEST_TRACKING_SHA" "$WRANGLE_SHA" 2>/dev/null; then
            printf 'No diff between %s (last tracking tag %s) and HEAD; nothing to do\n' \
                "$LATEST_TRACKING_SHA" "$LATEST_TRACKING_TAG"
            exit 0
        fi
        printf 'Diff detected between %s and HEAD; proceeding\n' "$LATEST_TRACKING_SHA"
    else
        # Last tracking tag's SHA isn't in the local clone (force-push
        # or fetch-depth too shallow). Proceed to push rather than
        # block on a transient.
        printf 'Last tracking tag %s embeds SHA %s, not present locally; proceeding\n' \
            "$LATEST_TRACKING_TAG" "$LATEST_TRACKING_SHA"
    fi
else
    printf 'No prior tracking tag on %s; bootstrapping\n' "$COMPANION_REPO"
fi

# Resolve the companion's main HEAD to use as the tag's target commit.
# See the asymmetry note in this script's header: the tag *name*
# encodes the wrangle SHA, but the tag *target* (and the showcase
# content) is wrangle-test/main HEAD.
if ! TARGET_SHA="$(gh api "repos/${COMPANION_REPO}/git/ref/heads/main" --jq .object.sha)"; then
    printf 'ERROR: could not resolve %s main HEAD\n' "$COMPANION_REPO" >&2
    exit 1
fi
if [[ -z "$TARGET_SHA" ]]; then
    printf 'ERROR: empty SHA returned for %s main HEAD\n' "$COMPANION_REPO" >&2
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
