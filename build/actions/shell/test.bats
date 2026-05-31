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

# --- Delegation to extracted scripts ----------------------------------------

@test "shell: run_shellcheck.sh and run_bats.sh exist and are executable" {
    [[ -x "$ACTION_DIR/run_shellcheck.sh" ]]
    [[ -x "$ACTION_DIR/run_bats.sh" ]]
}

@test "shell: action.yml delegates the shellcheck step to run_shellcheck.sh" {
    run grep -F 'run_shellcheck.sh' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "shell: action.yml delegates the bats step to run_bats.sh" {
    run grep -F 'run_bats.sh' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

# --- Workflow-command-injection guard (#225 / SLSA_L3_AUDIT.md Finding 3) ---

@test "shell: stop-commands guard helper exists and is executable" {
    [[ -x "$REPO_ROOT/lib/stop_commands_guard.sh" ]]
}

@test "shell: run_shellcheck.sh runs shellcheck under the stop-commands guard" {
    # shellcheck echoes excerpts of source lines in its diagnostics, and
    # the source files come from the caller's repo. A `.sh` file with a
    # line starting `::add-mask::` could reach the step log unguarded.
    # GUARD must resolve to lib/stop_commands_guard.sh and the xargs
    # invocation must spawn it, not bare shellcheck.
    run grep -F 'GUARD="$SCRIPT_DIR/../../../lib/stop_commands_guard.sh"' "$ACTION_DIR/run_shellcheck.sh"
    [[ "$status" -eq 0 ]]
    run grep -F 'xargs -0 -r "$GUARD" run shellcheck' "$ACTION_DIR/run_shellcheck.sh"
    [[ "$status" -eq 0 ]]
    # The unguarded `xargs -0 -r shellcheck` form must not creep back.
    run grep -E 'xargs -0 -r shellcheck([[:space:]]|$)' "$ACTION_DIR/run_shellcheck.sh"
    [[ "$status" -ne 0 ]]
}

@test "shell: run_bats.sh runs both invocation paths under the stop-commands guard" {
    # bats executes arbitrary user .bats files — a direct injection path
    # via printf '::add-mask::...'. BOTH branches (explicit bats-path
    # and auto-detected file list) must run under the guard.
    run grep -F 'GUARD="$SCRIPT_DIR/../../../lib/stop_commands_guard.sh"' "$ACTION_DIR/run_bats.sh"
    [[ "$status" -eq 0 ]]
    run grep -F '"$GUARD" run bats "$BATS_PATH"' "$ACTION_DIR/run_bats.sh"
    [[ "$status" -eq 0 ]]
    run grep -F '"$GUARD" run bats "${bats_files[@]}"' "$ACTION_DIR/run_bats.sh"
    [[ "$status" -eq 0 ]]
    # Bare `bats "$BATS_PATH"` / `bats "${bats_files[@]}"` (no guard)
    # must not creep back.
    run grep -E '^[[:space:]]+bats[[:space:]]+"\$BATS_PATH"[[:space:]]*$' "$ACTION_DIR/run_bats.sh"
    [[ "$status" -ne 0 ]]
    run grep -E '^[[:space:]]+bats[[:space:]]+"\$\{bats_files\[@\]}"[[:space:]]*$' "$ACTION_DIR/run_bats.sh"
    [[ "$status" -ne 0 ]]
}

# --- run_shellcheck.sh / run_bats.sh behavioral validation ------------------
# The path-validation rejections run before any tool is invoked, so they
# need neither shellcheck nor bats on PATH.

@test "shell: run_shellcheck.sh rejects an absolute scan-path" {
    run "$ACTION_DIR/run_shellcheck.sh" "/etc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"absolute paths not allowed"* ]]
}

@test "shell: run_shellcheck.sh rejects path traversal in scan-path" {
    run "$ACTION_DIR/run_shellcheck.sh" "../evil"
    [ "$status" -eq 1 ]
    [[ "$output" == *"path traversal not allowed"* ]]
}

@test "shell: run_shellcheck.sh rejects a nonexistent scan-path" {
    run "$ACTION_DIR/run_shellcheck.sh" "no_such_dir_xyz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "shell: run_shellcheck.sh usage error with no args" {
    run "$ACTION_DIR/run_shellcheck.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "shell: run_bats.sh rejects an absolute bats-path" {
    run "$ACTION_DIR/run_bats.sh" "/etc" "."
    [ "$status" -eq 1 ]
    [[ "$output" == *"absolute paths not allowed"* ]]
}

@test "shell: run_bats.sh skips cleanly when no .bats files are found" {
    local empty="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$empty"
    run "$ACTION_DIR/run_bats.sh" "" "$empty"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no .bats files found"* ]]
}

@test "shell: run_bats.sh usage error with wrong arg count" {
    run "$ACTION_DIR/run_bats.sh" "only-one"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}
