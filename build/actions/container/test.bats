#!/usr/bin/env bats

# Structural tests for build/actions/container/action.yml.
#
# Covers input-validation hardening specific to this action that
# neither zizmor nor actionlint check directly.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
}

@test "container: validate step disables globbing with set -f" {
    # The validate step must use set -f to disable globbing on external
    # input per CLAUDE.md's "scripts that process arguments from external
    # input MUST also set -f" rule. The container action builds a
    # Docker context path from user input, which is exactly that case.
    run grep -A5 'Validate and normalize inputs' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    run grep 'set -f' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}
