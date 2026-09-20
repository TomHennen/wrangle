#!/usr/bin/env bats

# Unit tests for tools/check_showcase_run_green.sh. A fake `gh` on PATH returns
# a fixture run list — the test needs deterministic run histories (specific
# conclusions and tag names) that no real API returns on demand.

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/check_showcase_run_green.sh"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN_DIR"
    export PATH="$BIN_DIR:$PATH" WRANGLE_RETRY_DELAY=0
    cat > "$BIN_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
[[ -n "${SHIM_GH_FAIL:-}" ]] && { printf 'gh: run list failed\n' >&2; exit 1; }
printf '%s\n' "${SHIM_RUNS:-[]}"
SHIM
    chmod +x "$BIN_DIR/gh"
}

@test "showcase run green: a green latest tracking-tag run passes (exit 0)" {
    export SHIM_RUNS='[{"conclusion":"success","url":"https://x/1","headBranch":"v20260919-abc1234","createdAt":"2026-09-19T00:00:00Z"}]'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"latest completed tracking-tag showcase run is green"* ]]
}

@test "showcase run green: a red latest tracking-tag run fails with its URL (exit 1)" {
    export SHIM_RUNS='[{"conclusion":"failure","url":"https://x/2","headBranch":"v20260919-abc1234","createdAt":"2026-09-19T00:00:00Z"}]'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"https://x/2"* ]]
    [[ "$output" == *"re-run it"* ]]
}

@test "showcase run green: a curated vX.Y.Z tag run is not mistaken for the tracking-tag heartbeat" {
    export SHIM_RUNS='[
        {"conclusion":"success","url":"https://x/curated","headBranch":"v0.4.1","createdAt":"2026-09-19T00:00:00Z"},
        {"conclusion":"failure","url":"https://x/tracking","headBranch":"v20260910-bbbbbbb","createdAt":"2026-09-10T00:00:00Z"}
    ]'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"https://x/tracking"* ]]
}

@test "showcase run green: queries wrangle-test's showcase workflow, completed runs only" {
    cat > "$BIN_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ARGS_LOG:?}"
printf '%s\n' "${SHIM_RUNS:-[]}"
SHIM
    chmod +x "$BIN_DIR/gh"
    export ARGS_LOG="$BATS_TEST_TMPDIR/args.log"
    export SHIM_RUNS='[{"conclusion":"success","url":"https://x/1","headBranch":"v20260919-abc1234","createdAt":"2026-09-19T00:00:00Z"}]'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- '--repo TomHennen/wrangle-test' "$ARGS_LOG"
    grep -q -- '--workflow showcase.yml' "$ARGS_LOG"
    grep -q -- '--status completed' "$ARGS_LOG"
}

@test "showcase run green: no completed tracking-tag run yet is UNVERIFIED (exit 2)" {
    export SHIM_RUNS='[]'
    run "$SCRIPT"
    [ "$status" -eq 2 ]
}

@test "showcase run green: API unreachable is UNVERIFIED (exit 2)" {
    export SHIM_GH_FAIL=1
    run "$SCRIPT"
    [ "$status" -eq 2 ]
}
