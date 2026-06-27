#!/usr/bin/env bats

# Exercises the locally-built zizmor tool image against the wrangle adapter
# contract (docs/tool_container_design.md §3.4): a clean pinned workflow ->
# exit 0 + empty SARIF, a deliberately tag-pinned workflow -> exit 1 + SARIF
# results, a tree with no workflows -> exit 0 (no inputs collected, a clean
# scan). Needs docker, so it lives under test/image/ (outside the Makefile's
# unit `bats` glob) and runs in the dogfooded shell build, which auto-detects
# every .bats on a docker-capable runner. The published image is digest-pinned
# in the catalog; this builds the image locally so the test never depends on
# pulling it.
#
# These tests pass NO token, so only zizmor's offline audits run (the
# unpinned-uses canary is offline). The online (GitHub-API) audits, which the
# catalog's secret: github-token enables in real runs, are not exercised here.

setup_file() {
    load "../lib/bats_helpers"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
    local root
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    wrangle_image_build zizmor -f "$root/tools/zizmor/Dockerfile" \
        -t wrangle-zizmor:test "$root"
}

setup() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    wrangle_require_docker
    docker image inspect wrangle-zizmor:test >/dev/null 2>&1 \
        || skip_or_fail "local zizmor image (wrangle-zizmor:test) not built"

    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-zz-img.XXXXXX")"
    OUT="$TMP_DIR/out"
    mkdir -p "$OUT"
    export ROOT TMP_DIR OUT
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

@test "zizmor image: hardened pinned workflow -> exit 0, empty SARIF" {
    local src="$TMP_DIR/clean"
    mkdir -p "$src/.github/workflows"
    cat > "$src/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
permissions: {}
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false
      - run: echo hi
YAML
    run wrangle_image_scan wrangle-zizmor:test "$src" "$OUT"
    [ "$status" -eq 0 ]
    wrangle_assert_sarif "$OUT"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

@test "zizmor image: tag-pinned action -> exit 1, SARIF results (unpinned-uses)" {
    local src="$TMP_DIR/findings"
    mkdir -p "$src/.github/workflows"
    cp "$ROOT/tools/zizmor/fixtures/unpinned_uses.yml" \
        "$src/.github/workflows/bad.yml"
    run wrangle_image_scan wrangle-zizmor:test "$src" "$OUT"
    [ "$status" -eq 1 ]
    wrangle_assert_sarif "$OUT"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -gt 0 ]
    [[ "$(jq -r '.runs[].results[].ruleId' "$OUT/output.sarif")" == *"unpinned-uses"* ]]
}

@test "zizmor image: tree with no workflows -> exit 0, empty SARIF" {
    local src="$TMP_DIR/empty"
    mkdir -p "$src"
    run wrangle_image_scan wrangle-zizmor:test "$src" "$OUT"
    [ "$status" -eq 0 ]
    wrangle_assert_sarif "$OUT"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}
