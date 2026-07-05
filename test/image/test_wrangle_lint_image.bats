#!/usr/bin/env bats

# Exercises the locally-built wrangle-lint tool image against the wrangle
# adapter contract (docs/tool_container_design.md §3.4): clean tree -> exit 0 +
# empty SARIF, a misconfiguration -> exit 1 + SARIF results. Needs docker, so it
# lives under test/image/ (outside the Makefile's unit `bats` glob) and runs in
# the dogfooded shell build, which auto-detects every .bats on a docker-capable
# runner. The published image is digest-pinned in the catalog; this builds the
# image locally so the test never depends on pulling it.

setup_file() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
    if wrangle_prebuilt_image wrangle-lint:test; then return 0; fi
    local root
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    docker build -q -f "$root/tools/wrangle-lint/Dockerfile" \
        -t wrangle-lint:test "$root" >/dev/null
}

setup() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    wrangle_require_docker
    docker image inspect wrangle-lint:test >/dev/null 2>&1 \
        || skip_or_fail "local wrangle-lint image (wrangle-lint:test) not built"

    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-wl-img.XXXXXX")"
    OUT="$TMP_DIR/out"
    mkdir -p "$OUT"
    export ROOT TMP_DIR OUT
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

@test "wrangle-lint image: well-configured repo -> exit 0, empty SARIF" {
    local src="$TMP_DIR/clean"
    mkdir -p "$src/.github"
    cp "$ROOT/tools/wrangle-lint/fixtures/good/.github/dependabot.yml" \
        "$src/.github/dependabot.yml"
    run wrangle_image_scan wrangle-lint:test "$src" "$OUT"
    [ "$status" -eq 0 ]
    wrangle_assert_sarif "$OUT"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

@test "wrangle-lint image: no Dependabot config -> exit 1, SARIF results (WL001)" {
    # An empty tree has no effective Dependabot configuration -> WL001 fires.
    local src="$TMP_DIR/findings"
    mkdir -p "$src"
    run wrangle_image_scan wrangle-lint:test "$src" "$OUT"
    [ "$status" -eq 1 ]
    wrangle_assert_sarif "$OUT"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -gt 0 ]
    [[ "$(jq -r '.runs[].results[].ruleId' "$OUT/output.sarif")" == *"WL001"* ]]
}
