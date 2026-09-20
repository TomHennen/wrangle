#!/usr/bin/env bats

# Unit tests for lib/gh_run_status.sh. A fake `gh` on PATH returns a fixture
# run list — the test needs deterministic run histories (specific conclusions,
# head refs, and orderings) that no real API returns on demand.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN_DIR"
    export PATH="$BIN_DIR:$PATH" WRANGLE_RETRY_DELAY=0
    # shellcheck source=../lib/gh_run_status.sh
    source "$REPO_ROOT/lib/gh_run_status.sh"
}

# Fake `gh run list`: prints $SHIM_RUNS (a JSON array), or fails when
# $SHIM_GH_FAIL is set.
install_gh() {
    cat > "$BIN_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
[[ -n "${SHIM_GH_FAIL:-}" ]] && { printf 'gh: run list failed\n' >&2; exit 1; }
printf '%s\n' "${SHIM_RUNS:-[]}"
SHIM
    chmod +x "$BIN_DIR/gh"
}

@test "gh_run_status: prints the conclusion and url of the newest matching completed run" {
    install_gh
    export SHIM_RUNS='[
        {"conclusion":"success","url":"https://x/1","headBranch":"v20260901-aaaaaaa","createdAt":"2026-09-01T00:00:00Z"},
        {"conclusion":"failure","url":"https://x/2","headBranch":"v20260910-bbbbbbb","createdAt":"2026-09-10T00:00:00Z"}
    ]'
    run wrangle_latest_completed_run TomHennen/wrangle-test showcase.yml '^v[0-9]{8}-[0-9a-f]{7}$'
    [ "$status" -eq 0 ]
    [[ "$output" == $'failure\thttps://x/2' ]]
}

@test "gh_run_status: picks the latest by createdAt, not list order" {
    install_gh
    export SHIM_RUNS='[
        {"conclusion":"failure","url":"https://x/older","headBranch":"main","createdAt":"2026-09-10T00:00:00Z"},
        {"conclusion":"success","url":"https://x/newer","headBranch":"main","createdAt":"2026-09-15T00:00:00Z"}
    ]'
    run wrangle_latest_completed_run TomHennen/wrangle catalog_freshness.yml '^main$'
    [ "$status" -eq 0 ]
    [[ "$output" == $'success\thttps://x/newer' ]]
}

@test "gh_run_status: a non-matching head ref is excluded, e.g. a curated release tag" {
    install_gh
    export SHIM_RUNS='[
        {"conclusion":"success","url":"https://x/curated","headBranch":"v0.4.1","createdAt":"2026-09-19T00:00:00Z"},
        {"conclusion":"failure","url":"https://x/tracking","headBranch":"v20260910-bbbbbbb","createdAt":"2026-09-10T00:00:00Z"}
    ]'
    run wrangle_latest_completed_run TomHennen/wrangle-test showcase.yml '^v[0-9]{8}-[0-9a-f]{7}$'
    [ "$status" -eq 0 ]
    [[ "$output" == $'failure\thttps://x/tracking' ]]
}

@test "gh_run_status: no completed run matching the ref regex fails closed (exit 2)" {
    install_gh
    export SHIM_RUNS='[{"conclusion":"success","url":"https://x/1","headBranch":"some-other-branch","createdAt":"2026-09-01T00:00:00Z"}]'
    run wrangle_latest_completed_run TomHennen/wrangle catalog_freshness.yml '^main$'
    [ "$status" -eq 2 ]
    [[ "$output" == *"no completed run"* ]]
}

@test "gh_run_status: an empty run list fails closed (exit 2)" {
    install_gh
    export SHIM_RUNS='[]'
    run wrangle_latest_completed_run TomHennen/wrangle catalog_freshness.yml '^main$'
    [ "$status" -eq 2 ]
}

@test "gh_run_status: a persistently failing API call is retried once, then fails closed (exit 2)" {
    install_gh
    export SHIM_GH_FAIL=1
    run wrangle_latest_completed_run TomHennen/wrangle catalog_freshness.yml '^main$'
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not list runs"* ]]
}

@test "gh_run_status: a transient API failure that clears on retry still succeeds" {
    local attempts="$BATS_TEST_TMPDIR/attempts"
    cat > "$BIN_DIR/gh" <<SHIM
#!/usr/bin/env bash
n=0
[[ -f "$attempts" ]] && n=\$(cat "$attempts")
n=\$((n + 1))
printf '%s' "\$n" > "$attempts"
if [[ "\$n" -eq 1 ]]; then
    printf 'gh: transient\n' >&2
    exit 1
fi
printf '%s\n' "\${SHIM_RUNS:-[]}"
SHIM
    chmod +x "$BIN_DIR/gh"
    export SHIM_RUNS='[{"conclusion":"success","url":"https://x/1","headBranch":"main","createdAt":"2026-09-01T00:00:00Z"}]'
    run wrangle_latest_completed_run TomHennen/wrangle catalog_freshness.yml '^main$'
    [ "$status" -eq 0 ]
    # The retry's own warning lands in $output too (stdout+stderr combined); the
    # evaluated result is the surviving attempt's last line.
    [[ "$output" == *$'success\thttps://x/1' ]]
    [[ "$(cat "$attempts")" == "2" ]]
}

@test "gh_run_status: missing gh is an env error (exit 2)" {
    local clean="$BATS_TEST_TMPDIR/clean"
    mkdir -p "$clean"
    for t in jq bash dirname mktemp cat; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$clean/$t"
    done
    PATH="$clean" run wrangle_latest_completed_run TomHennen/wrangle catalog_freshness.yml '^main$'
    [ "$status" -eq 2 ]
    [[ "$output" == *"gh and jq are required"* ]]
}
