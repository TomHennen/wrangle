#!/usr/bin/env bats

# Tests for tools/wrangle-lint/adapter.sh — the adapter wrapper around the
# first-party wrangle-lint Go binary. Rule-logic coverage (WL001–WL005,
# suppression, dogfood) lives in the fast Go table tests (main_test.go); this
# suite drives the real binary through the adapter to pin the wrapper contract:
# exit-code mapping (0/1/2), SARIF validity, and argument handling.

setup_file() {
    # Build the real binary once; the adapter resolves it on PATH (in CI run.sh
    # installs it via `go install tool`). go is in the test image; fail loud.
    WL_BIN_DIR="$(mktemp -d)"
    export WL_BIN_DIR
    go -C "$BATS_TEST_DIRNAME/.." build -o "$WL_BIN_DIR/wrangle-lint" ./wrangle-lint
}

teardown_file() {
    rm -rf "$WL_BIN_DIR"
}

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ADAPTER="$BATS_TEST_DIRNAME/adapter.sh"
    FIXTURES="$BATS_TEST_DIRNAME/fixtures"
    OUT="$(mktemp -d)"
    PATH="$WL_BIN_DIR:$PATH"
    export REPO_ROOT ADAPTER FIXTURES OUT PATH
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }
}

teardown() {
    rm -rf "$OUT"
}

@test "clean config: exit 0, no findings" {
    run "$ADAPTER" "$FIXTURES/good" "$OUT"
    [ "$status" -eq 0 ]
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

@test "a finding maps to exit 1 with valid SARIF" {
    run "$ADAPTER" "$FIXTURES/glob_ga" "$OUT"
    [ "$status" -eq 1 ]
    [ "$(jq -r '.runs[0].tool.driver.name' "$OUT/output.sarif")" = "wrangle-lint" ]
    [[ "$(jq -r '.runs[].results[].ruleId' "$OUT/output.sarif")" == *"WL003"* ]]
    [ "$(jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$OUT/output.sarif")" = ".github/dependabot.yml" ]
}

@test "a repo with no dependabot config is a finding (exit 1)" {
    src="$(mktemp -d)"
    run "$ADAPTER" "$src" "$OUT"
    rm -rf "$src"
    [ "$status" -eq 1 ]
    [[ "$(jq -r '.runs[].results[].ruleId' "$OUT/output.sarif")" == *"WL001"* ]]
}

@test "malformed dependabot.yml fails closed (exit 2)" {
    src="$(mktemp -d)"
    mkdir -p "$src/.github"
    printf 'updates:\n  - bad: [unclosed\n' > "$src/.github/dependabot.yml"
    run "$ADAPTER" "$src" "$OUT"
    rm -rf "$src"
    [ "$status" -eq 2 ]
}

@test "a missing output directory is a tool error (exit 2)" {
    run "$ADAPTER" "$FIXTURES/good" "$OUT/does-not-exist"
    [ "$status" -eq 2 ]
}

@test "dogfood: the wrangle repo's own config passes (exit 0)" {
    run "$ADAPTER" "$REPO_ROOT" "$OUT"
    [ "$status" -eq 0 ]
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}
