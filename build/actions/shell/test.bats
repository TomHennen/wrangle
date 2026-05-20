#!/usr/bin/env bats

# Structural tests for build/actions/shell/action.yml.
#
# Checks that the two load-bearing steps (shellcheck and bats) are
# present. Catches the regression "someone removed or renamed the
# bats step, shipping a shell build action that silently skips tests."

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
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

# --- Workflow-command-injection guard (#225 / SLSA_L3_AUDIT.md Finding 3) ---

@test "shell: stop-commands guard helper exists and is executable" {
    [[ -x "$REPO_ROOT/lib/stop_commands_guard.sh" ]]
}

@test "shell: shellcheck runs under the stop-commands guard" {
    # shellcheck echoes excerpts of source lines in its diagnostics, and
    # the source files come from the caller's repo. A `.sh` file with a
    # line starting `::add-mask::` could reach the step log unguarded.
    # The xargs invocation must spawn the guard, not bare shellcheck.
    run grep -F 'xargs -0 -r "${{ github.action_path }}/../../../lib/stop_commands_guard.sh" run shellcheck' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # The unguarded `xargs -0 -r shellcheck` form must not creep back.
    run grep -E '^[[:space:]]*-print0[[:space:]]*\|[[:space:]]*xargs -0 -r shellcheck[[:space:]]*$' "$ACTION_DIR/action.yml"
    [[ "$status" -ne 0 ]]
}

@test "shell: both bats invocation paths run under the stop-commands guard" {
    # bats executes arbitrary user .bats files — a direct injection path
    # via printf '::add-mask::...'. BOTH branches (explicit bats-path
    # and auto-detected file list) must run under the guard.
    run grep -F '"${{ github.action_path }}/../../../lib/stop_commands_guard.sh" run bats "$BATS_PATH"' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    run grep -F '"${{ github.action_path }}/../../../lib/stop_commands_guard.sh" run bats "${bats_files[@]}"' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # Bare `bats "$BATS_PATH"` / `bats "${bats_files[@]}"` (no guard)
    # must not creep back.
    run bash -c "grep -E '^[[:space:]]+bats[[:space:]]+\"\\\$BATS_PATH\"[[:space:]]*\$' \"$ACTION_DIR/action.yml\""
    [[ "$status" -ne 0 ]]
    run bash -c "grep -E '^[[:space:]]+bats[[:space:]]+\"\\\${bats_files\\[@\\]}\"[[:space:]]*\$' \"$ACTION_DIR/action.yml\""
    [[ "$status" -ne 0 ]]
}
