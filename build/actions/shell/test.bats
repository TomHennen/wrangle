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

@test "shell: has Run setup script step" {
    run grep 'Run setup script' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "shell: accepts setup-script input" {
    run grep 'setup-script:' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

# --- Reusable workflow scan job ---------------------------------------------
# build_shell.yml's scan is independent: there is no artifact to gate
# publishing of, so nothing downstream needs scan. A load-bearing finding
# fails the run alongside the shell build/test via the workflow conclusion.

@test "shell: workflow has a scan job using the scan action" {
    local wf="$REPO_ROOT/.github/workflows/build_shell.yml"
    run grep -E '^  scan:' "$wf"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$wf\" | grep -E 'uses:[[:space:]]*TomHennen/wrangle/actions/scan@'"
    [[ "$status" -eq 0 ]]
}

@test "shell: scan steps are gated on scan-tools so empty disables scanning" {
    # scan-tools: "" skips both steps; the scan job then concludes success.
    local wf="$REPO_ROOT/.github/workflows/build_shell.yml"
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$wf\" | grep -E \"if:.*inputs.scan-tools != ''\""
    [[ "$status" -eq 0 ]]
}

# --- Delegation to extracted scripts ----------------------------------------

@test "shell: run_shellcheck.sh, run_bats.sh and run_setup.sh exist and are executable" {
    [[ -x "$ACTION_DIR/run_shellcheck.sh" ]]
    [[ -x "$ACTION_DIR/run_bats.sh" ]]
    [[ -x "$ACTION_DIR/run_setup.sh" ]]
}

@test "shell: action.yml delegates the shellcheck step to run_shellcheck.sh" {
    run grep -F 'run_shellcheck.sh' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "shell: action.yml delegates the bats step to run_bats.sh" {
    run grep -F 'run_bats.sh' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "shell: action.yml delegates the setup step to run_setup.sh" {
    run grep -F 'run_setup.sh' "$ACTION_DIR/action.yml"
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

@test "shell: run_shellcheck.sh follows sourced libs (-x --source-path=SCRIPTDIR)" {
    # Without -x, findings in `source`d helpers are masked by SC1091. This
    # matches the depth the Makefile already holds wrangle's own scripts to.
    run grep -F 'run shellcheck -x --source-path=SCRIPTDIR' "$ACTION_DIR/run_shellcheck.sh"
    [[ "$status" -eq 0 ]]
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

@test "shell: run_setup.sh runs the setup-script under the stop-commands guard" {
    # The setup-script is arbitrary adopter bash and its install hooks print
    # tool-controlled output — a `printf '::add-mask::...'` injection path.
    run grep -F 'GUARD="$SCRIPT_DIR/../../../lib/stop_commands_guard.sh"' "$ACTION_DIR/run_setup.sh"
    [[ "$status" -eq 0 ]]
    run grep -F '"$GUARD" run bash "$SETUP_SCRIPT"' "$ACTION_DIR/run_setup.sh"
    [[ "$status" -eq 0 ]]
    # Bare `bash "$SETUP_SCRIPT"` (no guard) must not creep back.
    run grep -E '^[[:space:]]+bash[[:space:]]+"\$SETUP_SCRIPT"[[:space:]]*$' "$ACTION_DIR/run_setup.sh"
    [[ "$status" -ne 0 ]]
}

# --- run_shellcheck.sh / run_bats.sh behavioral validation ------------------
# The path-validation rejections run before any tool is invoked, so they
# need neither shellcheck nor bats on PATH.

@test "shell: run_shellcheck.sh rejects an absolute scan-path" {
    run "$ACTION_DIR/run_shellcheck.sh" "/etc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"path must be relative"* ]]
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
    [[ "$output" == *"path must be relative"* ]]
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

@test "shell: run_setup.sh is a no-op when setup-script is empty" {
    run "$ACTION_DIR/run_setup.sh" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"no setup-script provided, skipping"* ]]
}

@test "shell: run_setup.sh rejects an absolute setup-script path" {
    run "$ACTION_DIR/run_setup.sh" "/etc/passwd"
    [ "$status" -eq 1 ]
    [[ "$output" == *"path must be relative"* ]]
}

@test "shell: run_setup.sh rejects path traversal in setup-script" {
    run "$ACTION_DIR/run_setup.sh" "../evil.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"path traversal not allowed"* ]]
}

@test "shell: run_setup.sh rejects a setup-script that is not a file" {
    run "$ACTION_DIR/run_setup.sh" "no_such_setup_xyz.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a file"* ]]
}

@test "shell: run_setup.sh usage error with no args" {
    run "$ACTION_DIR/run_setup.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "shell: run_setup.sh runs a valid setup-script" {
    # Real script (no shim): a setup-script that creates a marker, exercising
    # the guarded `bash <path>` invocation end to end.
    local marker="$BATS_TEST_TMPDIR/ran"
    printf '#!/bin/bash\ntouch %q\n' "$marker" > "$BATS_TEST_TMPDIR/setup.sh"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/run_setup.sh" "setup.sh"
    [ "$status" -eq 0 ]
    [[ -f "$marker" ]]
    [[ "$output" == *"setup.sh completed"* ]]
}
