#!/usr/bin/env bats

# Tests for preflight_guard.sh — the trigger refusal logic prep runs at
# the head of every reusable workflow. Two flavors:
#
#   - Behavioral: run the script directly with EVENT_NAME / OUTER_EVENT set,
#     assert exit code + emitted message. These cover the refusal logic.
#   - Structural: grep-based fingerprints on prep's action.yml / the script.
#     These break loudly if a drive-by edit swaps the guard for a no-op step
#     or strips the env-passthrough pattern.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/preflight_guard.sh"
    PREP="$BATS_TEST_DIRNAME/action.yml"
}

# --- behavioral ---

@test "behavior: refuses pull_request_target" {
    EVENT_NAME=pull_request_target OUTER_EVENT="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"pull_request_target invocations"* ]]
}

@test "behavior: refuses workflow_run triggered by pull_request_target" {
    EVENT_NAME=workflow_run OUTER_EVENT=pull_request_target run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"workflow_run invocations triggered by pull_request_target"* ]]
}

@test "behavior: allows push" {
    EVENT_NAME=push OUTER_EVENT="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'Event "push" allowed.'* ]]
}

@test "behavior: allows workflow_dispatch" {
    EVENT_NAME=workflow_dispatch OUTER_EVENT="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "behavior: allows workflow_call" {
    EVENT_NAME=workflow_call OUTER_EVENT="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "behavior: allows workflow_run triggered by push (not pull_request_target)" {
    EVENT_NAME=workflow_run OUTER_EVENT=push run "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

# --- structural ---

@test "structure: script exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "structure: prep delegates to the script" {
    run grep 'preflight_guard.sh' "$PREP"
    [[ "$status" -eq 0 ]]
}

@test "structure: prep passes env vars (no expression interpolation into shell body)" {
    # EVENT_NAME and OUTER_EVENT must be passed via env:, not interpolated
    # into the script body. Matches wrangle's injection-safety convention.
    run grep -F 'EVENT_NAME: ${{ github.event_name }}' "$PREP"
    [[ "$status" -eq 0 ]]
    run grep -F 'OUTER_EVENT: ${{ github.event.workflow_run.event }}' "$PREP"
    [[ "$status" -eq 0 ]]
}

@test "structure: error message references the pwn-request vector" {
    # Fingerprint that survives editorial polish but breaks if the guard
    # is silently swapped for a no-op step.
    run grep -F "'pwn request' vector" "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "structure: error message points adopters at docs/SPEC.md#trigger-model" {
    run grep -F 'docs/SPEC.md#trigger-model' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}
