#!/usr/bin/env bats

# Structural tests for the slsa-verifier tool module.
#
# slsa-verifier lives in its own Go module rather than tools/go.mod
# because its sigstore dependency graph predates the one cosign + ampel
# share — a single module cannot satisfy both (MVS picks the newer graph
# and slsa-verifier no longer compiles). These tests guard the isolation
# and the pin.

setup() {
    TOOL_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
}

@test "slsa-verifier: go.mod pins the tool directive" {
    run grep -F 'tool github.com/slsa-framework/slsa-verifier/v2/cli/slsa-verifier' "$TOOL_DIR/go.mod"
    [ "$status" -eq 0 ]
}

@test "slsa-verifier: go.sum exists for sum-database integrity" {
    [[ -s "$TOOL_DIR/go.sum" ]]
}

@test "slsa-verifier: stays out of tools/go.mod (incompatible dep graphs)" {
    run grep -F 'slsa-verifier' "$REPO_ROOT/tools/go.mod"
    [ "$status" -ne 0 ]
}
