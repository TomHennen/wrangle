#!/usr/bin/env bats

# Structural tests for actions/prep/action.yml — the shared head-of-pipeline
# composite every reusable workflow runs as its first job. Asserts the three
# sub-actions are wired in the guard-first order, that the gate and names
# outputs are surfaced, and that an empty build-type is guard-only.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ACTION="$REPO_ROOT/actions/prep/action.yml"
}

@test "prep: runs preflight_guard before the gate and names steps" {
    guard_line="$(grep -n 'actions/preflight_guard@' "$ACTION" | head -1 | cut -d: -f1)"
    gate_line="$(grep -n 'actions/release_gate@' "$ACTION" | head -1 | cut -d: -f1)"
    names_line="$(grep -n 'actions/package_metadata@' "$ACTION" | head -1 | cut -d: -f1)"
    [ -n "$guard_line" ] && [ -n "$gate_line" ] && [ -n "$names_line" ]
    [ "$guard_line" -lt "$gate_line" ]
    [ "$gate_line" -lt "$names_line" ]
}

@test "prep: gate reads the release-events input" {
    run grep -F 'events: ${{ inputs.release-events }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "prep: gate and names are skipped in guard-only mode (empty build-type)" {
    # Both the gate and names steps must be gated on a non-empty build-type
    # so a scan/CI workflow heads with prep without deriving release/names.
    run grep -cF "if: \${{ inputs.build-type != '' }}" "$ACTION"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

@test "prep: should-release falls back to false when the gate is skipped" {
    run grep -F "value: \${{ steps.gate.outputs.should-release || 'false' }}" "$ACTION"
    [ "$status" -eq 0 ]
}

@test "prep: names derives from build-type + path" {
    run grep -F 'build-type: ${{ inputs.build-type }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'path: ${{ inputs.path }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "prep: surfaces shortname and the metadata names from the names step" {
    for out in shortname dist scan checks metadata metadata-pre provenance-bundle metadata-dir; do
        run grep -F "value: \${{ steps.names.outputs.$out }}" "$ACTION"
        [ "$status" -eq 0 ]
    done
}
