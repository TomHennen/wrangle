#!/usr/bin/env bats

# Structural tests for the preflight_guard composite action. Tests live
# next to the source like release_gate/ — they're grep-based fingerprints
# against the action script's refusal logic, not end-to-end runs.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    SCRIPT="$ACTION_DIR/preflight_guard.sh"
}

@test "preflight_guard: action.yml exists" {
    [[ -f "$ACTION" ]]
}

@test "preflight_guard: script exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "preflight_guard: action.yml delegates to the script" {
    run grep 'preflight_guard.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "preflight_guard: action.yml passes env vars (no expression interpolation into shell body)" {
    # EVENT_NAME and OUTER_EVENT must be passed via env:, not interpolated
    # into the script body. Matches wrangle's injection-safety convention.
    run grep -F 'EVENT_NAME: ${{ github.event_name }}' "$ACTION"
    [[ "$status" -eq 0 ]]
    run grep -F 'OUTER_EVENT: ${{ github.event.workflow_run.event }}' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "preflight_guard: refuses pull_request_target by name" {
    run grep -qF '"$EVENT_NAME" == "pull_request_target"' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "preflight_guard: refuses workflow_run triggered by pull_request_target" {
    run grep -qF '"$EVENT_NAME" == "workflow_run"' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    run grep -qF '"$OUTER_EVENT" == "pull_request_target"' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "preflight_guard: error message references the pwn-request vector" {
    # Fingerprint that survives editorial polish but breaks if the guard
    # is silently swapped for a no-op step.
    run grep -qF "'pwn request' vector" "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "preflight_guard: error message points adopters at docs/SPEC.md#trigger-model" {
    run grep -qF 'docs/SPEC.md#trigger-model' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "preflight_guard: script fails fast (exit 1, not exit 0 or signal-only)" {
    run grep -qE '^[[:space:]]*exit 1' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}
