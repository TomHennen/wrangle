#!/usr/bin/env bats

# Exercises the locally-built osv tool image against the wrangle adapter
# contract (docs/tool_container_design.md §3.4): a tree with no package sources
# -> exit 0 + empty SARIF, written by the adapter and the lib/ helpers shipped
# alongside it. Needs docker, so it lives under test/image/ (outside the
# Makefile's unit `bats` glob) and runs in the dogfooded shell build. The
# published image is digest-pinned in the catalog; this builds it locally so the
# test never depends on pulling it. The findings path needs the osv.dev API and
# is covered by the opt-in e2e in tools/osv/test.bats.

setup_file() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
    if wrangle_prebuilt_image osv:test; then return 0; fi
    local root
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    docker build -q -f "$root/tools/osv/Dockerfile" -t osv:test "$root" >/dev/null
}

setup() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    wrangle_require_docker
    docker image inspect osv:test >/dev/null 2>&1 \
        || skip_or_fail "local osv image (osv:test) not built"

    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-osv-img.XXXXXX")"
    OUT="$TMP_DIR/out"
    mkdir -p "$OUT"
    export TMP_DIR OUT
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

@test "osv image: no package sources -> exit 0, empty SARIF" {
    local src="$TMP_DIR/clean"
    mkdir -p "$src"
    printf 'hello\n' > "$src/README.md"
    run wrangle_image_scan osv:test "$src" "$OUT"
    [ "$status" -eq 0 ]
    wrangle_assert_sarif "$OUT"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
    wrangle_assert_src_unchanged "$src" 1
}
