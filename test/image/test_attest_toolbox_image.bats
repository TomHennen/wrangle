#!/usr/bin/env bats

# Builds the attest/verify toolbox image (tools/attest-toolbox/Dockerfile) and
# asserts the four signing-path binaries are present, runnable, and that the
# image runs non-root with HOME=/tmp. Needs docker, so it lives under test/image/
# (outside the Makefile's unit `bats` glob) and runs in the dogfooded shell
# build, which auto-detects every .bats on a docker-capable runner.

setup_file() {
    load "../lib/bats_helpers"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
    local root
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # Build context is the repo root (the Dockerfile builds from tools/go.mod).
    docker build -q -t wrangle-attest-toolbox:test \
        -f "$root/tools/attest-toolbox/Dockerfile" "$root" >/dev/null
}

setup() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    wrangle_require_docker
    IMG=wrangle-attest-toolbox:test
}

@test "attest-toolbox: ampel, bnd, cosign, wrangle-attest are on PATH" {
    local bin
    for bin in ampel bnd cosign wrangle-attest; do
        run docker run --rm --entrypoint sh "$IMG" -c "command -v $bin"
        [ "$status" -eq 0 ]
    done
}

@test "attest-toolbox: ampel reports its version" {
    run docker run --rm "$IMG" ampel version
    [ "$status" -eq 0 ]
    [[ "$output" == *v1.3.0* ]]
}

@test "attest-toolbox: cosign reports its version" {
    run docker run --rm "$IMG" cosign version
    [ "$status" -eq 0 ]
    [[ "$output" == *v3.0.6* ]]
}

@test "attest-toolbox: bnd runs" {
    run docker run --rm "$IMG" bnd version
    [ "$status" -eq 0 ]
}

@test "attest-toolbox: runs as a non-root user with HOME=/tmp" {
    run docker run --rm --entrypoint sh "$IMG" -c 'id -u; printf "%s" "$HOME"'
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" != "0" ]]
    [[ "${lines[1]}" == "/tmp" ]]
}
