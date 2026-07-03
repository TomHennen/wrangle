#!/usr/bin/env bats

# Proves the sbom kind is tool-agnostic: a NON-wrangle, off-namespace image that
# honors the sbom contract (/src ro -> /output/sbom.spdx.json, exit 0/2) is
# plugged in as an adopter's SBOM tool through the real BYO path — a
# .wrangle/tools.json added to the catalog (lib/merge_catalog.sh) and selected
# via WRANGLE_CUSTOM_TOOLS. One run exercises the whole seam: the dir-gate
# relaxation (no local tools/my-sbom/), the custom-tools union, the VSA gate
# skipping an off-namespace image, the contract sandbox, and a real (non-empty) SBOM.
#
# Needs docker + a throwaway registry (run.sh requires a registry digest pin), so
# it lives under test/image/ (outside the Makefile's unit bats glob) and runs in
# the dogfooded shell build on a docker-capable runner.

# A distinct host port from the other test/image registry sidecar
# (test_run_image_dispatch.bats uses 5000); bats runs files in parallel.
REGISTRY_IMAGE="registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
REGISTRY_PORT=5001
REGISTRY_HOST="localhost:${REGISTRY_PORT}"

_push_for_digest() {
    local local_tag="$1" ref="${REGISTRY_HOST}/$2:test"
    docker tag "$local_tag" "$ref" >/dev/null
    docker push -q "$ref" >/dev/null
    docker inspect --format '{{index .RepoDigests 0}}' "$ref"
}

setup_file() {
    load "../lib/bats_helpers"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
    local root
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    REGISTRY_CONTAINER="wrangle-test-byo-registry-$$"
    docker run -d -p "${REGISTRY_PORT}:5000" --name "$REGISTRY_CONTAINER" \
        "$REGISTRY_IMAGE" >/dev/null
    export REGISTRY_CONTAINER

    # An off-namespace contract-conforming image standing in for an adopter's own
    # SBOM tool; <src>/MODE selects sbom-real (a populated SPDX).
    docker build -q -t wrangle-mock-tool:test \
        "$root/test/fixtures/image-contract" >/dev/null
    BYO_IMAGE="$(_push_for_digest wrangle-mock-tool:test wrangle-byo-sbom)"
    export BYO_IMAGE
}

teardown_file() {
    if [[ -n "${REGISTRY_CONTAINER:-}" ]]; then
        docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
    fi
}

setup() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    wrangle_require_docker

    ORIG_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    RUN_SH="$ORIG_DIR/run.sh"
    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-byo.XXXXXX")"
    # WS is the adopter workspace: it holds the source tree and the override file,
    # and is the containment root run.sh validates the custom-tools path against.
    WS="$TMP_DIR/ws"
    SRC="$WS/src"
    OUT="$TMP_DIR/out"
    TOOLS="$TMP_DIR/tools"      # no my-sbom/ dir — the tool is catalog-only
    mkdir -p "$SRC" "$OUT" "$TOOLS" "$WS/.wrangle"
    printf 'sbom-real' > "$SRC/MODE"

    cat > "$WS/.wrangle/tools.json" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"$BYO_IMAGE"}}}
JSON
    export ORIG_DIR RUN_SH TMP_DIR WS SRC OUT TOOLS
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

_run_byo() {
    WRANGLE_TOOLS_DIR="$TOOLS" GITHUB_WORKSPACE="$WS" \
        WRANGLE_CUSTOM_TOOLS="$WS/.wrangle/tools.json" \
        run "$RUN_SH" -s "$SRC" -o "$OUT" my-sbom
}

@test "byo sbom: adopter image plugs in via custom-tools, no local tool dir" {
    _run_byo
    [ "$status" -eq 0 ]
    [ -f "$OUT/my-sbom/sbom.spdx.json" ]
    run jq empty "$OUT/my-sbom/sbom.spdx.json"
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.spdxVersion' "$OUT/my-sbom/sbom.spdx.json")" == SPDX-* ]]
    # Real inventory: at least one named package (not the valid-but-empty trap).
    [ "$(jq '.packages | length' "$OUT/my-sbom/sbom.spdx.json")" -gt 0 ]
    [ "$(jq '[.packages[] | select((.name // "") == "")] | length' "$OUT/my-sbom/sbom.spdx.json")" -eq 0 ]
}

@test "byo sbom: the sbom kind reaches the adopter image and drives its manifest" {
    _run_byo
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/my-sbom/kind_seen")" = "sbom" ]
    [ "$(jq -r '."predicate-type"' "$OUT/my-sbom/wrangle_attestation_metadata.json")" = "https://spdx.dev/Document" ]
    [ "$(jq -r '."result-file"' "$OUT/my-sbom/wrangle_attestation_metadata.json")" = "sbom.spdx.json" ]
}

@test "byo sbom: an off-namespace image skips the wrangle VSA gate (adopter-trusted)" {
    _run_byo
    [ "$status" -eq 0 ]
    [[ "$output" == *"non-wrangle image, not wrangle-identity-verified"* ]]
    [[ "$output" != *"VSA verified PASSED"* ]]
}

@test "byo sbom: the adopter image runs under the contract sandbox (src read-only)" {
    local before
    before="$(find "$SRC" -type f | wc -l | tr -d ' ')"
    _run_byo
    [ "$status" -eq 0 ]
    wrangle_assert_src_unchanged "$SRC" "$before"
    # Output is owned by the runner UID, not root — the sandbox's -u mapping.
    [ "$(stat -c '%u' "$OUT/my-sbom/sbom.spdx.json")" -eq "$(id -u)" ]
}

@test "byo sbom: end-to-end through generate_sbom lands the SBOM at the metadata root" {
    local meta="$TMP_DIR/meta"
    WRANGLE_TOOLS_DIR="$TOOLS" GITHUB_WORKSPACE="$WS" \
        WRANGLE_CUSTOM_TOOLS="$WS/.wrangle/tools.json" \
        run "$ORIG_DIR/lib/generate_sbom.sh" "$SRC" "$meta" my-sbom
    [ "$status" -eq 0 ]
    [ -f "$meta/sbom.spdx.json" ]
    [ "$(jq '.packages | length' "$meta/sbom.spdx.json")" -gt 0 ]
    [ ! -d "$meta/my-sbom" ]
}
