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

@test "python: workflow has separate publish job" {
    run grep 'publish:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: publish job gated on non-PR events" {
    run grep "startsWith(github.event_name, 'pull_')" "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: publish job uses pypi-publish action" {
    run grep 'pypa/gh-action-pypi-publish' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: publish enables PEP 740 attestations" {
    run grep 'attestations: true' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: workflow has provenance job" {
    run grep 'provenance:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: provenance uses SLSA generator by tag" {
    run grep 'generator_generic_slsa3.yml@v' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: workflow pins actions to SHAs" {
    # Every uses: with @ must have a 40-char hex SHA (except SLSA generator which uses tag)
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v 'slsa-github-generator' | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]  # no matches = all pinned
}
