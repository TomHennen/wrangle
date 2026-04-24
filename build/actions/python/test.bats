#!/usr/bin/env bats

# Structural tests for the Python build action and reusable workflow.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
    ACTION="$REPO_ROOT/build/actions/python/action.yml"
    WORKFLOW="$REPO_ROOT/.github/workflows/build_and_publish_python.yml"
}

# --- Composite action structural tests ---

@test "python: action.yml exists" {
    [[ -f "$ACTION" ]]
}

@test "python: validates path input" {
    run grep 'path must be relative\|path traversal\|invalid characters' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: validates pyproject.toml exists" {
    run grep 'pyproject.toml' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: detects uv.lock for tooling choice" {
    run grep 'uv.lock' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: supports uv build path" {
    run grep 'uv build\|uv sync\|uv run pytest' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: supports standard PEP 517 build path" {
    run grep 'python -m build' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: computes artifact hashes for SLSA" {
    run grep 'sha256sum\|base64' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: generates SBOM" {
    run grep 'spdx-json\|sbom' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: input validation disables globbing" {
    run grep 'set -f' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: passes inputs through env not interpolation" {
    # No ${{ inputs.* }} in run: blocks
    run grep -P 'run:.*\$\{\{.*inputs\.' "$ACTION"
    [[ "$status" -eq 1 ]]  # no matches = good
}

# --- Reusable workflow structural tests ---

@test "python: workflow exists" {
    [[ -f "$WORKFLOW" ]]
}

@test "python: workflow has build job with minimal permissions" {
    run grep -A2 'build:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    # Build job should only have contents: read
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep 'id-token'"
    [[ "$status" -eq 1 ]]  # no id-token in build job
}

@test "python: workflow is build-only (no publish job)" {
    # Publish must be in the adopter's workflow, not wrangle's reusable workflow,
    # because PyPI Trusted Publishing doesn't support reusable workflows.
    run grep '^  publish:' "$WORKFLOW"
    [[ "$status" -eq 1 ]]  # no publish job
}

@test "python: workflow exports hashes output for SLSA provenance" {
    run grep 'hashes:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: workflow documents PyPI reusable workflow limitation" {
    run grep 'warehouse/issues/11096\|Trusted Publishing.*reusable' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: workflow pins actions to SHAs" {
    # Every uses: with @ must have a 40-char hex SHA (except SLSA generator which uses tag)
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v 'slsa-github-generator' | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]  # no matches = all pinned
}
