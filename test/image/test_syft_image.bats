#!/usr/bin/env bats

# Exercises the locally-built syft tool image against the wrangle sbom-kind
# contract (docs/tool_container_design.md §3.3): a source tree -> exit 0 + a
# schema-valid sbom.spdx.json, and nothing written outside /output. Needs docker, so it
# lives under test/image/ (outside the Makefile's unit `bats` glob) and runs in
# the dogfooded shell build, which auto-detects every .bats on a docker-capable
# runner. The published image is digest-pinned in the catalog; this builds the
# image locally so the test never depends on pulling it (and the build itself
# runs the cosign verify chain, so it is network/Sigstore-dependent).

setup_file() {
    load "../lib/bats_helpers"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
    local root
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    docker build -q -f "$root/tools/syft/Dockerfile" \
        -t wrangle-syft:test "$root" >/dev/null
}

setup() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    wrangle_require_docker
    docker image inspect wrangle-syft:test >/dev/null 2>&1 \
        || skip_or_fail "local syft image (wrangle-syft:test) not built"

    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-syft-img.XXXXXX")"
    SRC="$TMP_DIR/src"
    OUT="$TMP_DIR/out"
    mkdir -p "$SRC" "$OUT"
    export TMP_DIR SRC OUT
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

# _run_syft — run the image under the contract sandbox (read-only src, non-root,
# network off).
_run_syft() {
    docker run --rm --network none -u "$(id -u):$(id -g)" \
        -v "$SRC":/src:ro -v "$OUT":/output wrangle-syft:test /src /output
}

@test "syft image: source tree -> exit 0, schema-valid sbom.spdx.json" {
    printf 'module example.com/x\n\ngo 1.21\n' > "$SRC/go.mod"
    run _run_syft
    [ "$status" -eq 0 ]
    [ -f "$OUT/sbom.spdx.json" ]
    run jq empty "$OUT/sbom.spdx.json"
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.spdxVersion' "$OUT/sbom.spdx.json")" == SPDX-* ]]
    [ -n "$(jq -r '.SPDXID' "$OUT/sbom.spdx.json")" ]
}

@test "syft image: writes nothing outside /output (src is read-only)" {
    printf 'module example.com/x\n\ngo 1.21\n' > "$SRC/go.mod"
    local before
    before="$(find "$SRC" -type f | wc -l | tr -d ' ')"
    run _run_syft
    [ "$status" -eq 0 ]
    wrangle_assert_src_unchanged "$SRC" "$before"
}
