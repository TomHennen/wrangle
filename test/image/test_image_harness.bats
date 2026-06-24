#!/usr/bin/env bats

# Validates the image test harness (test/lib/image_test_harness.bash) against a
# mock contract-conforming tool image, so the harness itself is trustworthy
# before real tool images rely on it. Needs docker, so it lives under test/image/
# (outside the Makefile's unit `bats` glob) and runs in the dogfooded shell
# build, which auto-detects every .bats on a docker-capable runner.

setup_file() {
    load "../lib/bats_helpers"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
    local root
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    docker build -q -t wrangle-mock-tool:test \
        "$root/test/fixtures/image-contract" >/dev/null
}

setup() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    wrangle_require_docker

    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-img.XXXXXX")"
    OUT="$TMP_DIR/out"
    mkdir -p "$OUT"
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

# Make a src fixture dir whose MODE file selects the mock's behavior.
_src_with_mode() {
    local mode="$1" dir="$TMP_DIR/src-$1"
    mkdir -p "$dir"
    printf '%s' "$mode" > "$dir/MODE"
    printf '%s' "$dir"
}

@test "harness: clean input -> exit 0 and valid empty SARIF" {
    local src
    src="$(_src_with_mode clean)"
    run wrangle_image_scan wrangle-mock-tool:test "$src" "$OUT"
    [ "$status" -eq 0 ]
    wrangle_assert_sarif "$OUT"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

@test "harness: findings -> exit 1 and SARIF with results" {
    local src
    src="$(_src_with_mode findings)"
    run wrangle_image_scan wrangle-mock-tool:test "$src" "$OUT"
    [ "$status" -eq 1 ]
    wrangle_assert_sarif "$OUT"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -gt 0 ]
}

@test "harness: tool error -> exit 2" {
    local src
    src="$(_src_with_mode error)"
    run wrangle_image_scan wrangle-mock-tool:test "$src" "$OUT"
    [ "$status" -eq 2 ]
}

@test "harness: assert_sarif catches malformed output" {
    local src
    src="$(_src_with_mode malformed)"
    run wrangle_image_scan wrangle-mock-tool:test "$src" "$OUT"
    [ "$status" -eq 0 ]
    run wrangle_assert_sarif "$OUT"
    [ "$status" -ne 0 ]
}

@test "harness: read-only src is enforced" {
    local src
    src="$(_src_with_mode clean)"
    run docker run --rm --network none -u "$(id -u):$(id -g)" \
        -v "$src":/src:ro -v "$OUT":/output --entrypoint /bin/sh \
        wrangle-mock-tool:test -c 'touch /src/x'
    [ "$status" -ne 0 ]
    wrangle_assert_src_unchanged "$src" 1
}
