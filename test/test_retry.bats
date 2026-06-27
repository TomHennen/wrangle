#!/usr/bin/env bats

# Unit tests for lib/retry.sh's wrangle_retry_once: capture stdout to a file,
# retry once on failure, never retry a success. Shared by the signing path and
# the pull-time VSA gate.

setup() {
    LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/retry.sh"
    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-retry.XXXXXX")"
    OUT="$TMP_DIR/out"
    CALLS="$TMP_DIR/calls"
    : > "$CALLS"
    # shellcheck source=/dev/null
    source "$LIB"
    export TMP_DIR OUT CALLS
    export WRANGLE_RETRY_DELAY=0
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

# A command that records each call and succeeds/fails per CALL_MODE.
_flaky() {
    printf 'x\n' >> "$CALLS"
    local n; n="$(wc -l < "$CALLS")"
    case "$CALL_MODE" in
        pass)        printf 'good\n'; return 0 ;;
        fail_once)   if [[ "$n" -eq 1 ]]; then printf 'partial\n'; return 1; fi
                     printf 'good\n'; return 0 ;;
        fail_always) printf 'broken\n'; return 1 ;;
    esac
}
export -f _flaky 2>/dev/null || true

@test "retry: a passing command runs exactly once and captures stdout" {
    CALL_MODE=pass run wrangle_retry_once "$OUT" _flaky
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$CALLS")" -eq 1 ]
    [ "$(cat "$OUT")" = "good" ]
}

@test "retry: a transient failure is retried once and then succeeds" {
    CALL_MODE=fail_once run wrangle_retry_once "$OUT" _flaky
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$CALLS")" -eq 2 ]
    # The surviving attempt's output is what the caller sees.
    [ "$(cat "$OUT")" = "good" ]
}

@test "retry: a persistent failure is retried once then propagates non-zero" {
    CALL_MODE=fail_always run wrangle_retry_once "$OUT" _flaky
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$CALLS")" -eq 2 ]
}
