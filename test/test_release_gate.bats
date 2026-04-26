#!/usr/bin/env bats

# Tests for actions/release_gate/release_gate.sh

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../actions/release_gate/release_gate.sh"
    export TEST_DIR="$(mktemp -d)"
    export GITHUB_OUTPUT="$TEST_DIR/output"
    : > "$GITHUB_OUTPUT"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Helper: run the gate with given env, return its output via $output and
# expose what was written to $GITHUB_OUTPUT via $gate_output.
run_gate() {
    : > "$GITHUB_OUTPUT"
    run env \
        EVENTS_INPUT="$1" \
        EVENT_NAME="$2" \
        REF="$3" \
        GITHUB_OUTPUT="$GITHUB_OUTPUT" \
        "$SCRIPT"
    gate_output="$(cat "$GITHUB_OUTPUT" 2>/dev/null || true)"
}

# --- non-pull-request shorthand ---

@test "non-pull-request: push event releases" {
    run_gate "non-pull-request" "push" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "non-pull-request: workflow_dispatch releases" {
    run_gate "non-pull-request" "workflow_dispatch" "refs/heads/feature"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "non-pull-request: schedule releases" {
    run_gate "non-pull-request" "schedule" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "non-pull-request: pull_request does NOT release" {
    run_gate "non-pull-request" "pull_request" "refs/pull/1/merge"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

@test "non-pull-request: pull_request_target does NOT release" {
    run_gate "non-pull-request" "pull_request_target" "refs/pull/1/merge"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

@test "non-pull-request: merge_group releases" {
    run_gate "non-pull-request" "merge_group" "refs/heads/gh-readonly-queue/main/pr-1-abc"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "non-pull-request: release event releases" {
    run_gate "non-pull-request" "release" "refs/tags/v1.0.0"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "non-pull-request: repository_dispatch releases" {
    run_gate "non-pull-request" "repository_dispatch" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

# --- tag-only shorthand ---

@test "tag-only: push to tag releases" {
    run_gate "tag-only" "push" "refs/tags/v1.0.0"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "tag-only: push to main does NOT release" {
    run_gate "tag-only" "push" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

@test "tag-only: workflow_dispatch does NOT release" {
    run_gate "tag-only" "workflow_dispatch" "refs/tags/v1.0.0"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

@test "tag-only: pull_request does NOT release" {
    run_gate "tag-only" "pull_request" "refs/pull/1/merge"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

@test "tag-only: release event does NOT release (event_name != push)" {
    # The github.event_name for a release publish is "release", not "push" —
    # so even though the ref is a tag, tag-only requires push specifically.
    run_gate "tag-only" "release" "refs/tags/v1.0.0"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

# --- main-and-tags shorthand ---

@test "main-and-tags: push to main releases" {
    run_gate "main-and-tags" "push" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "main-and-tags: push to tag releases" {
    run_gate "main-and-tags" "push" "refs/tags/v1.0.0"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "main-and-tags: push to feature branch does NOT release" {
    run_gate "main-and-tags" "push" "refs/heads/feature"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

@test "main-and-tags: workflow_dispatch on main does NOT release" {
    run_gate "main-and-tags" "workflow_dispatch" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

# --- comma-separated event list ---

@test "event-list: single matching event releases" {
    run_gate "workflow_dispatch" "workflow_dispatch" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "event-list: multiple events, one matches" {
    run_gate "push,workflow_dispatch" "workflow_dispatch" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "event-list: no match returns false" {
    run_gate "push,workflow_dispatch" "schedule" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

@test "event-list: tolerates spaces around commas" {
    run_gate "push , workflow_dispatch" "push" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "event-list: list with merge_group matches" {
    run_gate "push,merge_group" "merge_group" "refs/heads/gh-readonly-queue/main/pr-1-abc"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

# --- whitespace handling on shorthands ---

@test "shorthand: leading/trailing space tolerated on tag-only" {
    run_gate " tag-only " "push" "refs/tags/v1"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

@test "shorthand: leading/trailing space tolerated on non-pull-request" {
    run_gate "  non-pull-request" "push" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=true"* ]]
}

# --- invalid input ---

@test "invalid: empty input fails with exit 2" {
    run_gate "" "push" "refs/heads/main"
    [ "$status" -eq 2 ]
    [[ "$output" == *"empty"* ]]
}

@test "invalid: token with uppercase fails" {
    run_gate "Push" "push" "refs/heads/main"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid token"* ]]
}

@test "invalid: token with shell metachar fails" {
    run_gate "push;rm" "push" "refs/heads/main"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid token"* ]]
}

@test "invalid: CR in input fails" {
    run_gate $'tag-only\r' "push" "refs/tags/v1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CR/LF"* ]]
}

@test "invalid: unknown shorthand falls through to event-list and fails" {
    # 'main_only' has an underscore so passes the token regex; it just
    # doesn't match the event_name 'push', so it's not an *error* — it
    # returns false. This documents that shorthand-style typos with
    # valid characters silently return false.
    run_gate "main_only" "push" "refs/heads/main"
    [ "$status" -eq 0 ]
    [[ "$gate_output" == *"should-release=false"* ]]
}

@test "invalid: shorthand-like typo with hyphen fails (hyphen not in event_name regex)" {
    run_gate "tag-onyl" "push" "refs/tags/v1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid token"* ]]
}

# --- env var validation ---

@test "missing EVENTS_INPUT fails" {
    run env -u EVENTS_INPUT \
        EVENT_NAME="push" \
        REF="refs/heads/main" \
        GITHUB_OUTPUT="$GITHUB_OUTPUT" \
        "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "missing GITHUB_OUTPUT fails" {
    run env -u GITHUB_OUTPUT \
        EVENTS_INPUT="non-pull-request" \
        EVENT_NAME="push" \
        REF="refs/heads/main" \
        "$SCRIPT"
    [ "$status" -ne 0 ]
}
