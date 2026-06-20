#!/usr/bin/env bats

# Structural tests for actions/prep/action.yml — the shared head-of-pipeline
# composite the reusable build workflows run as their first job. Asserts the
# three sub-actions are wired in the guard-first order and that the gate and
# names outputs are surfaced for downstream jobs.

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

@test "prep: names derives from build-type + path" {
    run grep -F 'build-type: ${{ inputs.build-type }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'path: ${{ inputs.path }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "prep: surfaces should-release from the gate step" {
    run grep -F 'value: ${{ steps.gate.outputs.should-release }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "prep: surfaces shortname and the metadata names from the names step" {
    for out in shortname dist scan checks metadata metadata-pre provenance-bundle metadata-dir; do
        run grep -F "value: \${{ steps.names.outputs.$out }}" "$ACTION"
        [ "$status" -eq 0 ]
    done
}
