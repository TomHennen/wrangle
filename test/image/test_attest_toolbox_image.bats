#!/usr/bin/env bats

# Builds the attest/verify toolbox image (tools/attest-toolbox/Dockerfile) and
# asserts the four signing-path binaries are present, runnable, and that the
# image runs non-root with HOME=/tmp. Needs docker, so it lives under test/image/
# (outside the Makefile's unit `bats` glob) and runs in the dogfooded shell
# build, which auto-detects every .bats on a docker-capable runner.

setup_file() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
    if wrangle_prebuilt_image wrangle-attest-toolbox:test; then return 0; fi
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
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

ZERO_SUBJECT=sha256:0000000000000000000000000000000000000000000000000000000000000000
VSA_CONTEXT=expectedResourceUri:ghcr.io/x/y@sha256:abc,sourceRepo:https://github.com/x/y

# Run `ampel verify` in the image as the `docker run -u` value $1. The consumer
# VSA policy fetches no remote fragments, so --network none proves no egress is
# needed; the empty collector makes FAILED the expected verdict, but the VSA is
# still written.
wrangle_ampel_verify_in_image() {
    local user="$1" results="$2"
    mkdir -p "$results"
    : > "$results/bundle.jsonl"
    docker run --rm -u "$user" --network none -e HOME=/tmp \
        -v "$ROOT/policies":"$ROOT/policies":ro \
        -v "$results":"$results" \
        "$IMG" ampel verify \
        --subject="$ZERO_SUBJECT" \
        --collector="jsonl:$results/bundle.jsonl" \
        --policy="$ROOT/policies/wrangle-vsa-consumer-nonstrict-v1.hjson" \
        --context "$VSA_CONTEXT" \
        --workers=32 --exit-code=true --attest-results --attest-format=vsa \
        --results-path="$results/vsa.json" --format=html
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
    [[ "$output" == *v1.3.1* ]]
}

@test "attest-toolbox: cosign reports its version" {
    run docker run --rm "$IMG" cosign version
    [ "$status" -eq 0 ]
    [[ "$output" == *v3.0.6* ]]
}

@test "attest-toolbox: bnd reports its version" {
    run docker run --rm "$IMG" bnd version
    [ "$status" -eq 0 ]
    [[ "$output" == *v0.4.3* ]]
}

@test "attest-toolbox: runs as a non-root user with HOME=/tmp" {
    run docker run --rm --entrypoint sh "$IMG" -c 'id -u; printf "%s" "$HOME"'
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" != "0" ]]
    [[ "${lines[1]}" == "/tmp" ]]
}

@test "attest-toolbox: ampel verify writes a SLSA VSA under the runner UID" {
    local results="$BATS_TEST_TMPDIR/results"
    run wrangle_ampel_verify_in_image "$(id -u):$(id -g)" "$results"
    [ -f "$results/vsa.json" ]
    run jq -r '.predicateType' "$results/vsa.json"
    [ "$status" -eq 0 ]
    [ "$output" = "https://slsa.dev/verification_summary/v1" ]
}

@test "attest-toolbox: ampel verify has no /etc/passwd dependency (arbitrary UID)" {
    local results="$BATS_TEST_TMPDIR/anon"
    # World-writable so a UID absent from /etc/passwd (owning nothing) can write
    # the VSA — isolating the passwd question from the file-ownership constraint.
    mkdir -p "$results"
    chmod 0777 "$results"
    run wrangle_ampel_verify_in_image "99999:99999" "$results"
    [ -f "$results/vsa.json" ]
    run jq -r '.predicateType' "$results/vsa.json"
    [ "$status" -eq 0 ]
    [ "$output" = "https://slsa.dev/verification_summary/v1" ]
}
