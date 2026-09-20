#!/usr/bin/env bats

# Unit tests for tools/run_scheduled_check.sh. A fake `wrangle_alert.sh`
# sitting next to it records what it was called with — the test needs to
# assert the exact raise/clear wiring without actually filing GitHub issues.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    # A stand-in tools/ so the real wrangle_alert.sh is never invoked.
    TMP_DIR="$(mktemp -d)"
    mkdir -p "$TMP_DIR/tools"
    cp "$REPO_ROOT/tools/run_scheduled_check.sh" "$TMP_DIR/tools/"
    SCRIPT="$TMP_DIR/tools/run_scheduled_check.sh"
    ALERT_CALLS="$BATS_TEST_TMPDIR/alert_calls.log"
    cat > "$TMP_DIR/tools/wrangle_alert.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ALERT_CALLS:?}"
STUB
    chmod +x "$TMP_DIR/tools/wrangle_alert.sh"
    export ALERT_CALLS

    CHECK_PASS="$BATS_TEST_TMPDIR/check_pass.sh"
    printf '#!/usr/bin/env bash\nprintf "all good\\n"\n' > "$CHECK_PASS"
    chmod +x "$CHECK_PASS"

    CHECK_FAIL="$BATS_TEST_TMPDIR/check_fail.sh"
    printf '#!/usr/bin/env bash\nprintf "it broke: https://example/run/9\\n" >&2\nexit 1\n' > "$CHECK_FAIL"
    chmod +x "$CHECK_FAIL"

    CHECK_UNVERIFIED="$BATS_TEST_TMPDIR/check_unverified.sh"
    printf '#!/usr/bin/env bash\nprintf "backend unreachable\\n" >&2\nexit 2\n' > "$CHECK_UNVERIFIED"
    chmod +x "$CHECK_UNVERIFIED"

    CHECK_CRASH3="$BATS_TEST_TMPDIR/check_crash3.sh"
    printf '#!/usr/bin/env bash\nprintf "unexpected error\\n" >&2\nexit 3\n' > "$CHECK_CRASH3"
    chmod +x "$CHECK_CRASH3"

    CHECK_CRASH127="$BATS_TEST_TMPDIR/check_crash127.sh"
    printf '#!/usr/bin/env bash\nset -eu\nsome_missing_command\n' > "$CHECK_CRASH127"
    chmod +x "$CHECK_CRASH127"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "run_scheduled_check: a passing check clears the alert and exits 0" {
    run "$SCRIPT" mykey "My check is red" "$CHECK_PASS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"all good"* ]]
    grep -q -- 'clear mykey' "$ALERT_CALLS"
    ! grep -q -- 'raise' "$ALERT_CALLS"
}

@test "run_scheduled_check: a failing check raises the alert with the title and captured output, exits 1" {
    run "$SCRIPT" mykey "My check is red" "$CHECK_FAIL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"it broke"* ]]
    grep -q -- 'raise mykey My check is red' "$ALERT_CALLS"
    ! grep -q -- 'clear' "$ALERT_CALLS"
}

@test "run_scheduled_check: an unverified (exit 2) check warns, touches no alert, and exits 0" {
    run "$SCRIPT" mykey "My check is red" "$CHECK_UNVERIFIED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
    [[ "$output" == *"undetermined this run"* ]]
    [ ! -s "$ALERT_CALLS" ]
}

@test "run_scheduled_check: the check's own captured output (stdout+stderr) is echoed" {
    run "$SCRIPT" mykey "title" "$CHECK_FAIL"
    [[ "$output" == *"https://example/run/9"* ]]
}

@test "run_scheduled_check: the raised body-file argument is the check's own captured output" {
    cat > "$TMP_DIR/tools/wrangle_alert.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ALERT_CALLS:?}"
if [[ "$1" == "raise" ]]; then
    cat "$4" >> "${RAISED_BODY:?}"
fi
STUB
    chmod +x "$TMP_DIR/tools/wrangle_alert.sh"
    RAISED_BODY="$BATS_TEST_TMPDIR/raised_body.txt"
    : > "$RAISED_BODY"
    export RAISED_BODY
    run "$SCRIPT" mykey "title" "$CHECK_FAIL"
    [[ "$(cat "$RAISED_BODY")" == *"it broke: https://example/run/9"* ]]
}

@test "run_scheduled_check: a check that exits 3 (crash, not the documented 1) still raises, and exits 3" {
    run "$SCRIPT" mykey "My check is red" "$CHECK_CRASH3"
    [ "$status" -eq 3 ]
    grep -q -- 'raise mykey My check is red' "$ALERT_CALLS"
    ! grep -q -- 'clear' "$ALERT_CALLS"
}

@test "run_scheduled_check: a check that exits 127 (missing command) still raises, and exits 127" {
    run "$SCRIPT" mykey "My check is red" "$CHECK_CRASH127"
    [ "$status" -eq 127 ]
    grep -q -- 'raise mykey My check is red' "$ALERT_CALLS"
    ! grep -q -- 'clear' "$ALERT_CALLS"
}

@test "run_scheduled_check: the raised body notes the exit code for a non-1 failure" {
    cat > "$TMP_DIR/tools/wrangle_alert.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ALERT_CALLS:?}"
if [[ "$1" == "raise" ]]; then
    cat "$4" >> "${RAISED_BODY:?}"
fi
STUB
    chmod +x "$TMP_DIR/tools/wrangle_alert.sh"
    RAISED_BODY="$BATS_TEST_TMPDIR/raised_body.txt"
    : > "$RAISED_BODY"
    export RAISED_BODY
    run "$SCRIPT" mykey "title" "$CHECK_CRASH3"
    [[ "$(cat "$RAISED_BODY")" == *"check exited 3"* ]]
}

@test "run_scheduled_check: a failed raise is loud (::error::), not silently swallowed" {
    cat > "$TMP_DIR/tools/wrangle_alert.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ALERT_CALLS:?}"
[[ "$1" == "raise" ]] && exit 1
STUB
    chmod +x "$TMP_DIR/tools/wrangle_alert.sh"
    run "$SCRIPT" mykey "My check is red" "$CHECK_FAIL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"FAILED to file the wrangle-alert issue"* ]]
    grep -q -- 'raise mykey My check is red' "$ALERT_CALLS"
}

@test "run_scheduled_check: a failed clear stays quiet (clear may swallow errors on a green run)" {
    cat > "$TMP_DIR/tools/wrangle_alert.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ALERT_CALLS:?}"
[[ "$1" == "clear" ]] && exit 1
STUB
    chmod +x "$TMP_DIR/tools/wrangle_alert.sh"
    run "$SCRIPT" mykey "My check is red" "$CHECK_PASS"
    [ "$status" -eq 0 ]
    [[ "$output" != *"::error::"* ]]
}

@test "run_scheduled_check: usage error with too few args" {
    run "$SCRIPT" onlykey
    [ "$status" -eq 2 ]
}
