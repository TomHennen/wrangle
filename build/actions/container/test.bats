#!/usr/bin/env bats

# Structural tests for build/actions/container/action.yml.
#
# Covers input-validation hardening specific to this action that
# neither zizmor nor actionlint check directly.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
    GITHUB_OUTPUT="$(mktemp)"
    export GITHUB_OUTPUT
}

teardown() {
    rm -f "$GITHUB_OUTPUT"
}

@test "container: validate_inputs.sh exists and is executable" {
    [[ -x "$ACTION_DIR/validate_inputs.sh" ]]
}

@test "container: validate_inputs.sh disables globbing with set -f" {
    # External input flows into the script; CLAUDE.md requires set -f.
    run grep '^set -f' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml delegates input validation to validate_inputs.sh" {
    run grep 'validate_inputs.sh' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: validate_inputs.sh rejects absolute path" {
    run "$ACTION_DIR/validate_inputs.sh" "/etc" "ghcr.io" "ghcr.io/owner/img"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"path must be relative"* ]]
}

@test "container: validate_inputs.sh rejects traversal" {
    run "$ACTION_DIR/validate_inputs.sh" "../etc" "ghcr.io" "ghcr.io/owner/img"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"traversal"* ]]
}

@test "container: validate_inputs.sh rejects bad registry" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "BAD;REGISTRY" "ghcr.io/owner/img"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid registry"* ]]
}

@test "container: validate_inputs.sh rejects bad imagename" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "BAD IMAGE"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid image name"* ]]
}

@test "container: validate_inputs.sh writes path/imagename/shortname to GITHUB_OUTPUT" {
    run "$ACTION_DIR/validate_inputs.sh" "pkg/foo" "ghcr.io" "ghcr.io/owner/img"
    [[ "$status" -eq 0 ]]
    grep -q '^path=pkg/foo$' "$GITHUB_OUTPUT"
    grep -q '^imagename=ghcr.io/owner/img$' "$GITHUB_OUTPUT"
    grep -q '^shortname=pkg_foo$' "$GITHUB_OUTPUT"
}
