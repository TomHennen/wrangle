#!/usr/bin/env bats

# Tests for tools/wrangle-lint/adapter.sh — the wrapper around the wrangle-lint
# binary. The wrapper's job is exit-code mapping (0/1/2), SARIF validation, and
# argument handling; it is driven here with a shim on PATH that emits fixture
# SARIF. A shim (not the real binary) is the right tool: the wrapper's
# interesting branches are invalid-SARIF and tool-error, which a real scanner
# never emits on demand, and the rule engine + run() end-to-end are covered
# hermetically by the Go tests (main_test.go).

setup() {
    ADAPTER="$BATS_TEST_DIRNAME/adapter.sh"
    BIN_DIR="$(mktemp -d)"
    OUT="$(mktemp -d)"
    PATH="$BIN_DIR:$PATH"
    export ADAPTER BIN_DIR OUT PATH
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }
    # A fake wrangle-lint whose behavior is selected by $WL_SHIM_MODE and which
    # writes its SARIF to the output path the adapter passes as $2.
    cat >"$BIN_DIR/wrangle-lint" <<'SHIM'
#!/usr/bin/env bash
out="$2"
case "${WL_SHIM_MODE:-clean}" in
    clean)
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"wrangle-lint"}},"results":[]}]}\n' >"$out" ;;
    findings)
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"wrangle-lint"}},"results":[{"ruleId":"WL003","level":"error","message":{"text":"x"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":".github/dependabot.yml"},"region":{"startLine":1}}}]}]}]}\n' >"$out" ;;
    invalid)
        printf '{ not valid json\n' >"$out" ;;
    no-runs)
        printf '{}\n' >"$out" ;;
    toolerror)
        exit 2 ;;
esac
exit 0
SHIM
    chmod +x "$BIN_DIR/wrangle-lint"
}

teardown() {
    rm -rf "$BIN_DIR" "$OUT"
}

@test "no findings: exit 0" {
    WL_SHIM_MODE=clean run "$ADAPTER" "$BATS_TEST_DIRNAME" "$OUT"
    [ "$status" -eq 0 ]
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

@test "findings: exit 1, SARIF passed through" {
    WL_SHIM_MODE=findings run "$ADAPTER" "$BATS_TEST_DIRNAME" "$OUT"
    [ "$status" -eq 1 ]
    [ "$(jq -r '.runs[0].tool.driver.name' "$OUT/output.sarif")" = "wrangle-lint" ]
    [[ "$(jq -r '.runs[].results[].ruleId' "$OUT/output.sarif")" == *"WL003"* ]]
}

@test "binary tool error: exit 2" {
    WL_SHIM_MODE=toolerror run "$ADAPTER" "$BATS_TEST_DIRNAME" "$OUT"
    [ "$status" -eq 2 ]
}

@test "invalid SARIF from the binary: exit 2" {
    WL_SHIM_MODE=invalid run "$ADAPTER" "$BATS_TEST_DIRNAME" "$OUT"
    [ "$status" -eq 2 ]
}

@test "SARIF missing runs array: exit 2" {
    WL_SHIM_MODE=no-runs run "$ADAPTER" "$BATS_TEST_DIRNAME" "$OUT"
    [ "$status" -eq 2 ]
}

@test "missing source directory: exit 2" {
    run "$ADAPTER" "$OUT/does-not-exist" "$OUT"
    [ "$status" -eq 2 ]
}

@test "missing output directory: exit 2" {
    run "$ADAPTER" "$BATS_TEST_DIRNAME" "$OUT/does-not-exist"
    [ "$status" -eq 2 ]
}

@test "binary not on PATH: exit 2" {
    run env PATH="/usr/bin:/bin" "$ADAPTER" "$BATS_TEST_DIRNAME" "$OUT"
    [ "$status" -eq 2 ]
}
