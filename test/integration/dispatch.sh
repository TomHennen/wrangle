#!/usr/bin/env bash
set -euo pipefail

# Dispatch a workflow on the companion repo and wait for it to complete.
#
# Usage: dispatch.sh <wrangle_ref> <correlation_id>
#
# Environment:
#   GH_TOKEN          PAT with actions:write on the companion repo
#   COMPANION_REPO    Owner/repo of the companion (default: tomhennen/wrangle-test)
#   WORKFLOW_FILE     Workflow filename to dispatch (default: test-wrangle.yml)
#   POLL_INTERVAL     Seconds between polls when locating the run (default: 10)
#   LOCATE_TIMEOUT    Seconds to wait for the run to appear (default: 120)
#
# Exit codes:
#   0  Companion run succeeded
#   1  Companion run failed or was cancelled
#   2  Could not dispatch or locate the run

WRANGLE_REF="${1:?Usage: dispatch.sh <wrangle_ref> <correlation_id>}"
CORRELATION_ID="${2:?Usage: dispatch.sh <wrangle_ref> <correlation_id>}"

COMPANION_REPO="${COMPANION_REPO:-tomhennen/wrangle-test}"
WORKFLOW_FILE="${WORKFLOW_FILE:-test-wrangle.yml}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
LOCATE_TIMEOUT="${LOCATE_TIMEOUT:-120}"

# --- Dispatch ---

printf 'Dispatching %s on %s (ref=%s, correlation_id=%s)\n' \
  "$WORKFLOW_FILE" "$COMPANION_REPO" "$WRANGLE_REF" "$CORRELATION_ID"

if ! gh workflow run "$WORKFLOW_FILE" \
    --repo "$COMPANION_REPO" \
    -f wrangle_ref="$WRANGLE_REF" \
    -f correlation_id="$CORRELATION_ID"; then
  printf 'ERROR: Failed to dispatch workflow\n' >&2
  exit 2
fi

# --- Locate the dispatched run ---
# Poll recent runs of the workflow, filtering by our correlation_id.
# The run may take a few seconds to appear after dispatch.

printf 'Waiting for run to appear...\n'

RUN_ID=""
elapsed=0
while [[ -z "$RUN_ID" ]] && [[ "$elapsed" -lt "$LOCATE_TIMEOUT" ]]; do
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))

  # List recent runs and find ours by correlation_id in the inputs.
  # gh run list doesn't expose inputs, so we use the API directly.
  RUN_ID="$(gh api \
    "repos/${COMPANION_REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=10&status=queued&status=in_progress&status=waiting" \
    --jq ".workflow_runs[] |
      select(.head_branch == \"main\") |
      .id" 2>/dev/null | head -1 || true)"

  # If we found candidate runs, verify correlation_id via the run's inputs
  if [[ -n "$RUN_ID" ]]; then
    FOUND_CORR="$(gh api \
      "repos/${COMPANION_REPO}/actions/runs/${RUN_ID}" \
      --jq '.inputs.correlation_id // empty' 2>/dev/null || true)"
    if [[ "$FOUND_CORR" != "$CORRELATION_ID" ]]; then
      RUN_ID=""
    fi
  fi
done

if [[ -z "$RUN_ID" ]]; then
  printf 'ERROR: Could not locate dispatched run within %ds\n' "$LOCATE_TIMEOUT" >&2
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
