#!/usr/bin/env bash
set -euo pipefail

# Dispatch an integration test by pushing an ephemeral branch to the companion
# repo, then waiting for the resulting workflow run to complete.
#
# Usage: dispatch.sh <wrangle_sha> <pr_number>
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

WRANGLE_SHA="${1:?Usage: dispatch.sh <wrangle_sha> <pr_number>}"
PR_NUMBER="${2:?Usage: dispatch.sh <wrangle_sha> <pr_number>}"

COMPANION_REPO="${COMPANION_REPO:-tomhennen/wrangle-test}"
WRANGLE_REPO="${WRANGLE_REPO:-TomHennen/wrangle}"
TEMPLATE_FILE="${TEMPLATE_FILE:-.github/workflows/test-wrangle.yml.template}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
LOCATE_TIMEOUT="${LOCATE_TIMEOUT:-120}"

SHORT_SHA="${WRANGLE_SHA:0:7}"
BRANCH_NAME="integration/pr-${PR_NUMBER}-${SHORT_SHA}"
GENERATED_FILE=".github/workflows/test-wrangle.yml"
CLEANUP_BRANCH=""

# shellcheck disable=SC2317 # invoked indirectly via trap
cleanup() {
    if [[ -n "$CLEANUP_BRANCH" ]]; then
        printf 'Cleaning up: deleting branch %s from %s\n' "$CLEANUP_BRANCH" "$COMPANION_REPO"
        gh api "repos/${COMPANION_REPO}/git/refs/heads/${CLEANUP_BRANCH}" \
            --method DELETE 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Clone companion repo (shallow, single-branch) ---

WORK_DIR="$(mktemp -d)"
printf 'Cloning %s into %s\n' "$COMPANION_REPO" "$WORK_DIR"

# Use GH_TOKEN for HTTPS auth
git clone --depth 1 --single-branch \
    "https://x-access-token:${GH_TOKEN}@github.com/${COMPANION_REPO}.git" \
    "$WORK_DIR" 2>/dev/null

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

# --- Create ephemeral branch and push ---

printf 'Creating branch %s\n' "$BRANCH_NAME"

cd "$WORK_DIR"
git checkout -b "$BRANCH_NAME"

# Write generated workflow file
mkdir -p "$(dirname "$GENERATED_FILE")"
printf '%s\n' "$GENERATED_CONTENT" > "$GENERATED_FILE"

git add "$GENERATED_FILE"
git -c user.name="wrangle-integration" -c user.email="wrangle-integration@noreply" \
    commit -m "Integration test for wrangle PR #${PR_NUMBER} at ${SHORT_SHA}" --quiet

# Push and record branch for cleanup
git push origin "$BRANCH_NAME" --quiet 2>/dev/null
CLEANUP_BRANCH="$BRANCH_NAME"

PUSHED_SHA="$(git rev-parse HEAD)"
printf 'Pushed ephemeral branch %s (commit: %s)\n' "$BRANCH_NAME" "$PUSHED_SHA"

# --- Locate the dispatched run ---
# Poll workflow runs filtered by the pushed commit's SHA.

printf 'Waiting for companion run to appear...\n'

RUN_ID=""
elapsed=0
while [[ -z "$RUN_ID" ]] && [[ "$elapsed" -lt "$LOCATE_TIMEOUT" ]]; do
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))

    RUN_ID="$(gh api \
        "repos/${COMPANION_REPO}/actions/runs?head_sha=${PUSHED_SHA}&event=push" \
        --jq '.workflow_runs[0].id // empty' 2>/dev/null || true)"
done

if [[ -z "$RUN_ID" ]]; then
    printf 'ERROR: Could not locate companion run within %ds (head_sha=%s)\n' \
        "$LOCATE_TIMEOUT" "$PUSHED_SHA" >&2
    exit 2
fi

printf 'Found run: %s\n' "$RUN_ID"

# --- Wait for completion ---

printf 'Watching run %s...\n' "$RUN_ID"
if gh run watch "$RUN_ID" --repo "$COMPANION_REPO" --exit-status; then
    printf 'Companion run succeeded.\n'
    exit 0
else
    printf 'Companion run failed.\n' >&2
    exit 1
fi
