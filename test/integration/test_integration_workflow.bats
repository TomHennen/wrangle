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

@test "integration-test.yml passes inputs through env" {
    run grep 'WRANGLE_REF:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'CORRELATION_ID:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "integration-test.yml uses concurrency group" {
    run grep 'concurrency:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "integration-test.yml pins actions to SHAs" {
    # Every uses: with @ must have a 40-char hex SHA
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]  # no matches = all pinned
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
    # No bare echo statements (echo with no flags for user-facing output)
    run grep -c '^[[:space:]]*echo ' "$DISPATCH"
    [[ "$output" = "0" ]]
}
