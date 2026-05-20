#!/usr/bin/env bats

# Structural tests for the release-showcase workflow and its tag-push script.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/release-showcase.yml"
    SCRIPT="$REPO_ROOT/test/integration/push_showcase_tag.sh"
}

# --- Workflow structural tests ---

@test "release-showcase.yml exists" {
    [[ -f "$WORKFLOW" ]]
}

@test "release-showcase.yml triggers on push to main with paths filter" {
    run grep -E 'branches:.*main' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep '^    paths:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "release-showcase.yml runs only on path changes that affect adopters" {
    # Reusable workflows, composite actions, orchestrator, libs, tool adapters.
    for path_pattern in '.github/workflows/build_' 'actions/**' 'run.sh' 'tools/**'; do
        run grep -F "$path_pattern" "$WORKFLOW"
        [[ "$status" -eq 0 ]]
    done
}

@test "release-showcase.yml uses environment gating for the cross-repo PAT" {
    run grep 'environment: integration-test' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "release-showcase.yml does not interpolate secrets in run blocks" {
    run grep -P 'run:.*\$\{\{.*secrets\.' "$WORKFLOW"
    [[ "$status" -eq 1 ]]
}

@test "release-showcase.yml passes wrangle SHA through env" {
    run grep 'WRANGLE_SHA:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "release-showcase.yml uses a serializing concurrency group" {
    run grep 'concurrency:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'cancel-in-progress: false' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "release-showcase.yml pins actions to SHAs" {
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]
}

@test "release-showcase.yml uses persist-credentials: false on checkout" {
    # No git credentials needed; the gh CLI uses GH_TOKEN.
    run grep 'persist-credentials: false' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

# --- Script structural tests ---

@test "push_showcase_tag.sh exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "push_showcase_tag.sh starts with set -euo pipefail" {
    run head -3 "$SCRIPT"
    [[ "$output" == *"set -euo pipefail"* ]]
}

@test "push_showcase_tag.sh uses printf not echo for output" {
    run grep -c '^[[:space:]]*echo ' "$SCRIPT"
    [[ "$output" = "0" ]]
}

@test "push_showcase_tag.sh validates GH_TOKEN is set" {
    run grep 'GH_TOKEN' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh composes tag as vYYYYMMDD-<sha>" {
    # The script must include both the date stamp and the short SHA in the tag.
    run grep 'date -u +%Y%m%d' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    run grep 'SHORT_SHA=' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    run grep 'TAG="v' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh is idempotent on rerun (checks tag existence first)" {
    # Must look up the ref before attempting to create it — otherwise a
    # workflow_dispatch rerun would 422 on the duplicate POST.
    run grep 'git/ref/tags/' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh targets the companion repo's main HEAD" {
    run grep 'git/ref/heads/main' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh creates the tag via gh api refs POST" {
    run grep 'git/refs' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    run grep 'method POST\|--method POST' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}
