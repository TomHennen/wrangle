#!/usr/bin/env bats

# Tests for lib/stop_commands_guard.sh — the ::stop-commands:: guard that
# neutralizes GitHub Actions workflow-command injection via build-tool
# stdout. See docs/SLSA_L3_AUDIT.md Finding 3.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$REPO_ROOT/lib/stop_commands_guard.sh"
    GITHUB_OUTPUT="$(mktemp)"
    export GITHUB_OUTPUT
}

teardown() {
    rm -f "$GITHUB_OUTPUT"
}

@test "stop_commands_guard: exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "stop_commands_guard: rejects an unknown subcommand" {
    run "$SCRIPT" bogus
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "stop_commands_guard: rejects no subcommand" {
    run "$SCRIPT"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

# --- run ---

@test "stop_commands_guard: run rejects a missing command" {
    run "$SCRIPT" run
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "stop_commands_guard: run emits stop-commands, the output, then a matching re-enable" {
    run "$SCRIPT" run printf 'BUILD-OUTPUT\n'
    [[ "$status" -eq 0 ]]
    # Line 1: ::stop-commands::<token>
    [[ "${lines[0]}" == ::stop-commands::* ]]
    local token="${lines[0]#::stop-commands::}"
    # Line 2: the wrapped command's output, verbatim.
    [[ "${lines[1]}" == "BUILD-OUTPUT" ]]
    # Line 3: the re-enable line, using the SAME token.
    [[ "${lines[2]}" == "::${token}::" ]]
}

@test "stop_commands_guard: run token is 64 hex characters (256-bit)" {
    run "$SCRIPT" run true
    [[ "$status" -eq 0 ]]
    local token="${lines[0]#::stop-commands::}"
    [[ "$token" =~ ^[0-9a-f]{64}$ ]]
}

@test "stop_commands_guard: run token is freshly random on every invocation" {
    run "$SCRIPT" run true
    local token1="${lines[0]#::stop-commands::}"
    run "$SCRIPT" run true
    local token2="${lines[0]#::stop-commands::}"
    [[ -n "$token1" ]]
    [[ "$token1" != "$token2" ]]
}

@test "stop_commands_guard: run preserves the wrapped command's exit status" {
    run "$SCRIPT" run bash -c 'exit 7'
    [[ "$status" -eq 7 ]]
}

@test "stop_commands_guard: run re-enables commands even when the wrapped command fails" {
    # The re-enable line is load-bearing: stop-commands is job-scoped, so
    # a failed build that left commands suspended would disable
    # ::add-mask:: secret redaction for the rest of the job.
    run "$SCRIPT" run bash -c 'exit 1'
    [[ "$status" -eq 1 ]]
    local token="${lines[0]#::stop-commands::}"
    [[ "${lines[${#lines[@]}-1]}" == "::${token}::" ]]
}

@test "stop_commands_guard: run passes every argument through to the wrapped command" {
    run "$SCRIPT" run bash -c 'printf "[%s]" "$@"' _ one "two three" four
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"[one][two three][four]"* ]]
}

@test "stop_commands_guard: run does not export the token into the wrapped command's environment" {
    # The guarded build must not be able to read the token — otherwise it
    # could emit a matching ::<token>:: and re-enable commands itself.
    # The guard keeps `token` as a plain (unexported) shell variable.
    run "$SCRIPT" run bash -c 'printf "token=[%s]\n" "${token:-UNSET}"'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"token=[UNSET]"* ]]
}

@test "stop_commands_guard: run uses an EXIT trap so re-enable runs even on script abort" {
    # Stop-commands is job-scoped — leaving it suspended would disable
    # ::add-mask:: secret redaction for the rest of the job. The explicit
    # re-enable printf could in principle fail (closed stdout) and set -e
    # would then exit before the line was emitted. An EXIT trap closes
    # that window. Structural assertion: a trap on EXIT must exist in the
    # `run` path, and the trap body must reference the token variable.
    run grep -E '^[[:space:]]*trap.*EXIT' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"$token"'* ]]
}

@test "stop_commands_guard: run trap re-enables even when generate_token has not yet run" {
    # Belt-and-suspenders: if anything aborted the script BEFORE the
    # token was generated, the trap must not itself fail (and must not
    # emit a malformed `::::` re-enable). Verified indirectly: the trap
    # guards on [[ -n "$token" ]], and token is initialized to "" before
    # the trap is installed.
    run grep -F 'token=""' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    run grep -F '[[ -n "$token" ]] && printf' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

# --- begin ---

@test "stop_commands_guard: begin writes the token to GITHUB_OUTPUT and emits stop-commands" {
    run "$SCRIPT" begin
    [[ "$status" -eq 0 ]]
    [[ "${lines[0]}" == ::stop-commands::* ]]
    local emitted="${lines[0]#::stop-commands::}"
    # The step-output token must match the emitted stop-commands token.
    run grep -E "^stop-commands-token=${emitted}\$" "$GITHUB_OUTPUT"
    [[ "$status" -eq 0 ]]
}

@test "stop_commands_guard: begin token is 64 hex characters" {
    run "$SCRIPT" begin
    [[ "$status" -eq 0 ]]
    run bash -c "grep -oE '^stop-commands-token=.*' \"$GITHUB_OUTPUT\" | cut -d= -f2"
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "stop_commands_guard: begin fails when GITHUB_OUTPUT is unset" {
    run env -u GITHUB_OUTPUT "$SCRIPT" begin
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"GITHUB_OUTPUT"* ]]
}

@test "stop_commands_guard: begin rejects extra arguments" {
    run "$SCRIPT" begin extra
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

# --- end ---

@test "stop_commands_guard: end emits the re-enable line for the given token" {
    run "$SCRIPT" end abcdef0123
    [[ "$status" -eq 0 ]]
    [[ "$output" == "::abcdef0123::" ]]
}

@test "stop_commands_guard: end is a no-op for an empty token" {
    # The end step runs with if: always(); when an earlier failure skipped
    # begin, the token is empty and end must emit nothing.
    run "$SCRIPT" end ""
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "stop_commands_guard: end requires exactly one token argument" {
    run "$SCRIPT" end
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
    run "$SCRIPT" end tok1 tok2
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "stop_commands_guard: begin/end round-trip uses one consistent token" {
    run "$SCRIPT" begin
    local token="${lines[0]#::stop-commands::}"
    run "$SCRIPT" end "$token"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "::${token}::" ]]
}
