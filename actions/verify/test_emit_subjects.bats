#!/usr/bin/env bats

# Tests for actions/verify/emit_subjects.sh — the shared subjects resolver the
# npm/go/python verify steps used to duplicate.

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/emit_subjects.sh"
    GITHUB_OUTPUT="$(mktemp)"
    export GITHUB_OUTPUT
}

teardown() {
    rm -f "$GITHUB_OUTPUT"
}

@test "expands a dist-files JSON array to dist/<file> subjects" {
    DIST_FILES='["app-1.2.3.tgz","app-1.2.3.whl"]' SUBJECTS_IN="" run "$SCRIPT"
    [ "$status" -eq 0 ]
    run cat "$GITHUB_OUTPUT"
    [[ "$output" == *"subjects<<WRANGLE_EOF"* ]]
    [[ "$output" == *"dist/app-1.2.3.tgz"* ]]
    [[ "$output" == *"dist/app-1.2.3.whl"* ]]
}

@test "passes SUBJECTS_IN through verbatim" {
    SUBJECTS_IN=$'sha256:abc\nsha256:def' DIST_FILES="" run "$SCRIPT"
    [ "$status" -eq 0 ]
    run cat "$GITHUB_OUTPUT"
    [[ "$output" == *"sha256:abc"* ]]
    [[ "$output" == *"sha256:def"* ]]
}

@test "fails closed on a malformed dist-files array" {
    DIST_FILES='not json' SUBJECTS_IN="" run "$SCRIPT"
    [ "$status" -ne 0 ]
}
