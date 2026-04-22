#!/usr/bin/env bats

# Structural tests for the integration-test workflow and dispatch script.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/integration-test.yml"
    DISPATCH="$REPO_ROOT/test/integration/dispatch.sh"
}

# --- Workflow structural tests ---

@test "integration-test.yml exists" {
    [[ -f "$WORKFLOW" ]]
}

@test "integration-test.yml triggers on pull_request only" {
    # Must not use pull_request_target — that would give fork PRs secret access
    run grep -c 'pull_request_target' "$WORKFLOW"
    [[ "$output" = "0" ]]
}

@test "integration-test.yml has fork-PR guard" {
    run grep 'head.repo.full_name == github.repository' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "integration-test.yml does not interpolate secrets in run blocks" {
    # Secrets must flow through env:, never directly in run:
    run grep -P 'run:.*\$\{\{.*secrets\.' "$WORKFLOW"
    [[ "$status" -eq 1 ]]  # grep exits 1 = no match = good
}

@test "integration-test.yml passes wrangle SHA through env" {
    run grep 'WRANGLE_SHA:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "integration-test.yml passes PR number through env" {
    run grep 'PR_NUMBER:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "integration-test.yml uses per-PR concurrency group" {
    run grep 'concurrency:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'pull_request.number' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "integration-test.yml has cancel-in-progress" {
    run grep 'cancel-in-progress: true' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "integration-test.yml pins actions to SHAs" {
    # Every uses: with @ must have a 40-char hex SHA
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]  # no matches = all pinned
}

@test "integration-test.yml has always() cleanup step" {
    run grep "if: always()" "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

# --- Dispatch script structural tests ---

@test "dispatch.sh exists and is executable" {
    [[ -x "$DISPATCH" ]]
}

@test "dispatch.sh starts with set -euo pipefail" {
    run head -3 "$DISPATCH"
    [[ "$output" == *"set -euo pipefail"* ]]
}

@test "dispatch.sh uses printf not echo for output" {
    # No bare echo statements
    run grep -c '^[[:space:]]*echo ' "$DISPATCH"
    [[ "$output" = "0" ]]
}

@test "dispatch.sh performs __WRANGLE_SHA__ token assertion before substitution" {
    run grep '__WRANGLE_SHA__' "$DISPATCH"
    [[ "$status" -eq 0 ]]
    # Must check token count before substitution — match the variable assignment, not comments
    run grep 'TOKEN_COUNT_BEFORE=' "$DISPATCH"
    [[ "$status" -eq 0 ]]
}

@test "dispatch.sh performs __WRANGLE_SHA__ token assertion after substitution" {
    run grep 'TOKEN_COUNT_AFTER=' "$DISPATCH"
    [[ "$status" -eq 0 ]]
}

@test "dispatch.sh performs workflow coverage check" {
    run grep 'workflow_call\|coverage' "$DISPATCH"
    [[ "$status" -eq 0 ]]
}

@test "dispatch.sh uses head_sha for run location (not most-recent-run heuristic)" {
    run grep 'head_sha' "$DISPATCH"
    [[ "$status" -eq 0 ]]
}

@test "dispatch.sh cleans up ephemeral branch on exit" {
    run grep 'trap cleanup EXIT' "$DISPATCH"
    [[ "$status" -eq 0 ]]
}

@test "dispatch.sh uses shallow single-branch clone" {
    run grep '\-\-depth 1' "$DISPATCH"
    [[ "$status" -eq 0 ]]
    run grep '\-\-single-branch' "$DISPATCH"
    [[ "$status" -eq 0 ]]
}
