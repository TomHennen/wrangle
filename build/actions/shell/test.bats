#!/usr/bin/env bats

# Structural tests for build/actions/shell/action.yml.
#
# Checks that the two load-bearing steps (shellcheck and bats) are
# present. Catches the regression "someone removed or renamed the
# bats step, shipping a shell build action that silently skips tests."

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
}

@test "shell: has Run shellcheck step" {
    run grep 'Run shellcheck' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "shell: has Run bats tests step" {
    run grep 'Run bats' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "shell: accepts scan-path input" {
    run grep 'scan-path:' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}
