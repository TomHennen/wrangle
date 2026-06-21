#!/usr/bin/env bash
set -euo pipefail
set -f

# Dispatch an integration test by pushing an ephemeral tag to the companion
# repo, then waiting for the resulting workflow run to complete.
#
# The tag is `pr-<pr_number>-<wrangle_run_id>` (both numeric). It puts the
# companion run in a tag context, so wrangle's tag-gated verify creates a
# temporary release and attaches the attested asset set that the companion's
# golden job asserts (TomHennen/wrangle#506). The companion's
# cleanup-integration.yml reaper prunes the tag + release — it matches
# `^pr-[0-9]+-[0-9]+$`, which only this numeric tag shape satisfies.
#
# Usage: dispatch.sh <wrangle_sha> <pr_number> <wrangle_run_id>
#
# Environment:
#   GH_TOKEN          PAT with contents:write on the companion repo
#   COMPANION_REPO    Owner/repo of the companion (default: tomhennen/wrangle-test)
#   WRANGLE_REPO      Owner/repo of wrangle (default: TomHennen/wrangle)
#   TEMPLATE_FILE     Template path in companion repo (default: .github/workflows/test-wrangle.yml.template)
#   POLL_INTERVAL     Seconds between polls when locating the run (default: 10)
#   LOCATE_TIMEOUT    Seconds to wait for the run to appear (default: 120)
#
# Exit codes:
#   0  Companion run succeeded
#   1  Companion run failed or was cancelled
#   2  Could not dispatch or locate the run (infrastructure / template error)

WRANGLE_SHA="${1:?Usage: dispatch.sh <wrangle_sha> <pr_number> <wrangle_run_id>}"
PR_NUMBER="${2:?Usage: dispatch.sh <wrangle_sha> <pr_number> <wrangle_run_id>}"
WRANGLE_RUN_ID="${3:?Usage: dispatch.sh <wrangle_sha> <pr_number> <wrangle_run_id>}"

# Numeric-only allowlist: both segments flow into the pushed tag name and into
# git/gh commands. Reject (fail closed) anything that isn't all-digits before
# any command sees the value.
if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: PR_NUMBER must be numeric (got %q)\n' "$PR_NUMBER" >&2
    exit 2
fi
if [[ ! "$WRANGLE_RUN_ID" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: WRANGLE_RUN_ID must be numeric (got %q)\n' "$WRANGLE_RUN_ID" >&2
    exit 2
fi

COMPANION_REPO="${COMPANION_REPO:-tomhennen/wrangle-test}"
WRANGLE_REPO="${WRANGLE_REPO:-TomHennen/wrangle}"
TEMPLATE_FILE="${TEMPLATE_FILE:-.github/workflows/test-wrangle.yml.template}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
LOCATE_TIMEOUT="${LOCATE_TIMEOUT:-120}"

SHORT_SHA="${WRANGLE_SHA:0:7}"
TAG_NAME="pr-${PR_NUMBER}-${WRANGLE_RUN_ID}"
GENERATED_FILE=".github/workflows/test-wrangle.yml"
CLEANUP_TAG=""

# shellcheck disable=SC2317 # invoked indirectly via trap
cleanup() {
    if [[ -n "$CLEANUP_TAG" ]]; then
        printf 'Cleaning up: deleting tag %s from %s\n' "$CLEANUP_TAG" "$COMPANION_REPO"
        gh api "repos/${COMPANION_REPO}/git/refs/tags/${CLEANUP_TAG}" \
            --method DELETE 2>/dev/null || true
        gh release delete "$CLEANUP_TAG" --repo "$COMPANION_REPO" --yes 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Pre-flight checks ---

if [[ -z "${GH_TOKEN:-}" ]]; then
    printf 'ERROR: GH_TOKEN not set (need contents:write on companion repo)\n' >&2
    exit 2
fi

# --- Clone companion repo (shallow, single-branch) ---

WORK_DIR="$(mktemp -d)"
printf 'Cloning %s into %s\n' "$COMPANION_REPO" "$WORK_DIR"

# Use GH_TOKEN for HTTPS auth — mask the token from logs
git clone --depth 1 --single-branch \
    "https://x-access-token:${GH_TOKEN}@github.com/${COMPANION_REPO}.git" \
    "$WORK_DIR" 2>&1 | grep -v 'x-access-token' || true

# --- Read and validate template ---

TEMPLATE_PATH="${WORK_DIR}/${TEMPLATE_FILE}"
if [[ ! -f "$TEMPLATE_PATH" ]]; then
    printf 'ERROR: Template not found at %s in %s\n' "$TEMPLATE_FILE" "$COMPANION_REPO" >&2
    exit 2
fi

TEMPLATE_CONTENT="$(cat "$TEMPLATE_PATH")"

# Assertion 1: Token presence before substitution
TOKEN_COUNT_BEFORE="$(printf '%s' "$TEMPLATE_CONTENT" | grep -c '__WRANGLE_SHA__' || true)"
if [[ "$TOKEN_COUNT_BEFORE" -eq 0 ]]; then
    printf 'ERROR: Template contains no __WRANGLE_SHA__ tokens — template is malformed\n' >&2
    exit 2
fi
printf 'Template contains %d __WRANGLE_SHA__ token(s)\n' "$TOKEN_COUNT_BEFORE"

# --- Perform substitution ---

GENERATED_CONTENT="${TEMPLATE_CONTENT//__WRANGLE_SHA__/${WRANGLE_SHA}}"

# Assertion 2: Token absence after substitution
TOKEN_COUNT_AFTER="$(printf '%s' "$GENERATED_CONTENT" | grep -c '__WRANGLE_SHA__' || true)"
if [[ "$TOKEN_COUNT_AFTER" -ne 0 ]]; then
    printf 'ERROR: %d __WRANGLE_SHA__ token(s) remain after substitution\n' "$TOKEN_COUNT_AFTER" >&2
    exit 2
fi

# Assertion 3: Workflow coverage check
# Every workflow_call-triggered .yml in wrangle must have a uses: line in the generated file.
printf 'Checking workflow coverage...\n'

# Get list of wrangle reusable workflows (workflow_call triggers) at the PR's head SHA
WRANGLE_WORKFLOWS="$(gh api "repos/${WRANGLE_REPO}/git/trees/${WRANGLE_SHA}?recursive=1" \
    --jq '.tree[] | select(.path | startswith(".github/workflows/")) | select(.path | endswith(".yml")) | .path' 2>/dev/null)" || {
    printf 'ERROR: Failed to list wrangle workflows at %s\n' "$WRANGLE_SHA" >&2
    exit 2
}

MISSING_WORKFLOWS=""
while IFS= read -r workflow_path; do
    [[ -z "$workflow_path" ]] && continue
    workflow_basename="$(basename "$workflow_path")"

    # Check if this workflow has workflow_call trigger by fetching its content
    workflow_content="$(gh api "repos/${WRANGLE_REPO}/contents/${workflow_path}?ref=${WRANGLE_SHA}" \
        --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)" || continue

    if printf '%s' "$workflow_content" | grep -q 'workflow_call' 2>/dev/null; then
        # This is a reusable workflow — check it's referenced in the generated file
        if ! printf '%s' "$GENERATED_CONTENT" | grep -q "${workflow_basename}@" 2>/dev/null; then
            MISSING_WORKFLOWS="${MISSING_WORKFLOWS}  - ${workflow_path}\n"
        fi
    fi
done <<< "$WRANGLE_WORKFLOWS"

if [[ -n "$MISSING_WORKFLOWS" ]]; then
    printf 'ERROR: The following reusable workflows are not referenced in the companion template:\n' >&2
    printf '%b' "$MISSING_WORKFLOWS" >&2
    printf 'Update %s in %s to include them.\n' "$TEMPLATE_FILE" "$COMPANION_REPO" >&2
    exit 2
fi
printf 'All reusable workflows are covered by the template.\n'

# --- Create the generated-workflow commit and push it as an ephemeral tag ---

printf 'Creating ephemeral tag %s\n' "$TAG_NAME"

cd "$WORK_DIR"

# Write generated workflow file onto a detached commit; only the tag is pushed.
mkdir -p "$(dirname "$GENERATED_FILE")"
printf '%s\n' "$GENERATED_CONTENT" > "$GENERATED_FILE"

git add "$GENERATED_FILE"
git -c user.name="wrangle-integration" -c user.email="wrangle-integration@noreply" \
    commit -m "Integration test for wrangle PR #${PR_NUMBER} at ${SHORT_SHA}" --quiet

git tag "$TAG_NAME"

# Push the tag and record it for cleanup. The tag context is what makes
# wrangle's verify produce a real release for the golden to assert.
if ! git push origin "refs/tags/${TAG_NAME}" 2>&1; then
    printf 'ERROR: Failed to push tag %s to %s\n' "$TAG_NAME" "$COMPANION_REPO" >&2
    exit 2
fi
CLEANUP_TAG="$TAG_NAME"

PUSHED_SHA="$(git rev-parse HEAD)"
printf 'Pushed ephemeral tag %s (commit: %s)\n' "$TAG_NAME" "$PUSHED_SHA"

# --- Locate the dispatched run ---
# A tag push fires event=push with head_sha = the tagged commit, so the
# locate poll is keyed identically to the prior branch-push flow.

printf 'Waiting for companion run to appear...\n'

COMPANION_RUN_ID=""
elapsed=0
while [[ -z "$COMPANION_RUN_ID" ]] && [[ "$elapsed" -lt "$LOCATE_TIMEOUT" ]]; do
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))

    COMPANION_RUN_ID="$(gh api \
        "repos/${COMPANION_REPO}/actions/runs?head_sha=${PUSHED_SHA}&event=push" \
        --jq '.workflow_runs[0].id // empty' 2>/dev/null || true)"
done

if [[ -z "$COMPANION_RUN_ID" ]]; then
    printf 'ERROR: Could not locate companion run within %ds (head_sha=%s)\n' \
        "$LOCATE_TIMEOUT" "$PUSHED_SHA" >&2
    exit 2
fi

printf 'Found run: %s\n' "$COMPANION_RUN_ID"

# --- Wait for completion ---

printf 'Watching run %s...\n' "$COMPANION_RUN_ID"
if gh run watch "$COMPANION_RUN_ID" --repo "$COMPANION_REPO" --exit-status; then
    printf 'Companion run succeeded.\n'
    exit 0
else
    printf 'Companion run failed.\n' >&2
    exit 1
fi
