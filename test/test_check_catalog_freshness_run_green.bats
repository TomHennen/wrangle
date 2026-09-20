#!/usr/bin/env bats

# Unit tests for tools/check_catalog_freshness_run_green.sh. A fake `gh` on
# PATH returns a fixture run list — the test needs deterministic run histories
# (specific conclusions and branches) that no real API returns on demand.

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/check_catalog_freshness_run_green.sh"
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

@test "catalog freshness run green: a green latest main run passes (exit 0)" {
    export SHIM_RUNS='[{"conclusion":"success","url":"https://x/1","headBranch":"main","createdAt":"2026-09-19T00:00:00Z"}]'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is green"* ]]
}

@test "catalog freshness run green: a red latest main run fails with its URL (exit 1)" {
    export SHIM_RUNS='[{"conclusion":"failure","url":"https://x/2","headBranch":"main","createdAt":"2026-08-31T09:17:00Z"}]'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"https://x/2"* ]]
    [[ "$output" == *"re-run it"* ]]
}

@test "catalog freshness run green: a run on a non-main branch is not mistaken for the scheduled one" {
    export SHIM_RUNS='[{"conclusion":"success","url":"https://x/pr","headBranch":"some-feature-branch","createdAt":"2026-09-19T00:00:00Z"}]'
    run "$SCRIPT"
    [ "$status" -eq 2 ]
}

@test "catalog freshness run green: queries wrangle's own catalog_freshness.yml on main, completed only" {
    cat > "$BIN_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ARGS_LOG:?}"
printf '%s\n' "${SHIM_RUNS:-[]}"
SHIM
    chmod +x "$BIN_DIR/gh"
    export ARGS_LOG="$BATS_TEST_TMPDIR/args.log"
    export SHIM_RUNS='[{"conclusion":"success","url":"https://x/1","headBranch":"main","createdAt":"2026-09-19T00:00:00Z"}]'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- '--repo TomHennen/wrangle' "$ARGS_LOG"
    grep -q -- '--workflow catalog_freshness.yml' "$ARGS_LOG"
    grep -q -- '--status completed' "$ARGS_LOG"
}

@test "catalog freshness run green: no completed run on main yet is UNVERIFIED (exit 2)" {
    export SHIM_RUNS='[]'
    run "$SCRIPT"
    [ "$status" -eq 2 ]
}

@test "catalog freshness run green: API unreachable is UNVERIFIED (exit 2)" {
    export SHIM_GH_FAIL=1
    run "$SCRIPT"
    [ "$status" -eq 2 ]
}
