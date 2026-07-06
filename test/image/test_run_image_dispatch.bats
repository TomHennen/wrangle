#!/usr/bin/env bats

# Validates run.sh's catalog-driven image dispatch (#596,
# docs/tool_container_design.md §3.5): a tool whose catalog entry names an image
# is run via `docker run` under the contract sandbox, writing the SAME
# ${output_dir}/${tool}/output.sarif the downstream collectors consume, with the
# 0/1/2 exit contract mapped.
#
# Needs docker, so it lives under test/image/ (outside the Makefile's unit
# `bats` glob, which expands test/ non-recursively) and runs in the dogfooded
# shell build, which auto-detects every .bats on a docker-capable runner.
#
# The deterministic dispatch tests drive run.sh against a mock contract image
# (no network, exit/output selectable) so they assert run.sh's seam, not osv's
# scanning. A separate test exercises the real, locally-built osv image.

# A throwaway local registry gives a locally-built image a REAL repo digest
# that resolves on any engine; run.sh's digest-pin check rejects a tag, and a
# bare image ID resolves only on the containerd image store (empty RepoDigests
# on classic overlay2). Pin registry:2 by digest (docker dependabot covers /**).
REGISTRY_IMAGE="registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
REGISTRY_PORT=5000
REGISTRY_HOST="localhost:${REGISTRY_PORT}"

# _push_for_digest <local-tag> <repo-name> — tag into the local registry, push,
# and echo the engine-portable <host>/<repo>@sha256:<digest> reference.
_push_for_digest() {
    local local_tag="$1" ref="${REGISTRY_HOST}/$2:test"
    docker tag "$local_tag" "$ref" >/dev/null
    docker push -q "$ref" >/dev/null
    docker inspect --format '{{index .RepoDigests 0}}' "$ref"
}

setup_file() {
    load "../lib/bats_helpers"
    load "../lib/image_test_harness.sh"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
    local root
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    REGISTRY_CONTAINER="wrangle-test-registry-$$"
    docker run -d -p "${REGISTRY_PORT}:5000" --name "$REGISTRY_CONTAINER" \
        "$REGISTRY_IMAGE" >/dev/null
    export REGISTRY_CONTAINER

    # Mock contract image: <src>/MODE selects clean|findings|error.
    docker build -q -t wrangle-mock-tool:test \
        "$root/test/fixtures/image-contract" >/dev/null
    MOCK_IMAGE="$(_push_for_digest wrangle-mock-tool:test wrangle-mock-tool)"
    export MOCK_IMAGE

    # The osv tool image, built locally from this repo (the published image is
    # private; unit tests must not depend on pulling it). Best-effort: the
    # real-osv test below skips when this image isn't present.
    if wrangle_prebuilt_image wrangle-osv:test \
        || docker build -q -f "$root/tools/osv/Dockerfile" -t wrangle-osv:test \
            "$root" >/dev/null 2>&1; then
        OSV_IMAGE="$(_push_for_digest wrangle-osv:test wrangle-osv)"
        export OSV_IMAGE
    fi
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
    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-run-img.XXXXXX")"
    SRC="$TMP_DIR/src"
    OUT="$TMP_DIR/out"
    TOOLS="$TMP_DIR/tools"
    mkdir -p "$SRC" "$OUT" "$TOOLS/mocktool"

    # MOCK_IMAGE is the local-registry digest pin from setup_file (a real,
    # engine-portable repo digest, which run.sh's digest-pin check requires).
    export ORIG_DIR RUN_SH TMP_DIR SRC OUT TOOLS

    # A mock catalog declaring mocktool as a curated image tool pointing at
    # the local mock image. network omitted -> none (the default).
    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"mocktool":{"kind":"scan","image":"$MOCK_IMAGE"}}}
JSON
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

_run_orch() {
    WRANGLE_TOOLS_DIR="$TOOLS" run "$RUN_SH" -s "$SRC" -o "$OUT" "$@"
}

@test "run.sh image dispatch: clean -> exit 0 and valid empty SARIF" {
    printf 'clean' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    wrangle_assert_sarif "$OUT/mocktool"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/mocktool/output.sarif")" -eq 0 ]
}

@test "run.sh image dispatch: findings -> exit 1 and SARIF with results" {
    printf 'findings' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 1 ]
    wrangle_assert_sarif "$OUT/mocktool"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/mocktool/output.sarif")" -gt 0 ]
}

@test "run.sh image dispatch: tool error -> exit 2 and an error marker" {
    printf 'error' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 2 ]
    # The marker lets check_results catch the failure even under continue-on-error
    # (and honor an :info policy on the error).
    [ -f "$OUT/mocktool/error" ]
}

@test "run.sh image dispatch: an errored tool among several -> exit 2" {
    # Two tools, both erroring, in one run; overall status must reach 2 (an error
    # is never downgraded).
    printf 'error' > "$SRC/MODE"
    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"toola":{"kind":"scan","image":"$MOCK_IMAGE"},"toolb":{"kind":"scan","image":"$MOCK_IMAGE"}}}
JSON
    _run_orch toola toolb
    [ "$status" -eq 2 ]
}

@test "run.sh image dispatch: run timeout -> exit 2" {
    printf 'slow' > "$SRC/MODE"
    WRANGLE_TOOLS_DIR="$TOOLS" WRANGLE_ADAPTER_TIMEOUT=1 \
        run "$RUN_SH" -s "$SRC" -o "$OUT" mocktool
    [ "$status" -eq 2 ]
    [[ "$output" == *"timed out"* ]]
}

@test "run.sh image dispatch: two image tools land in distinct dirs without clobbering" {
    printf 'clean' > "$SRC/MODE"
    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"toola":{"kind":"scan","image":"$MOCK_IMAGE"},"toolb":{"kind":"scan","image":"$MOCK_IMAGE"}}}
JSON
    _run_orch toola toolb
    [ "$status" -eq 0 ]
    [ -f "$OUT/toola/output.sarif" ]
    [ -f "$OUT/toolb/output.sarif" ]
}

@test "run.sh image dispatch: writes the scan/v1 manifest for a wired tool token" {
    # run.sh's shared post-run path writes the scan/v1 manifest for osv/wrangle-lint/
    # zizmor tokens. Drive it deterministically with the mock image under the osv key.
    printf 'clean' > "$SRC/MODE"
    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"osv":{"kind":"scan","image":"$MOCK_IMAGE"}}}
JSON
    _run_orch osv
    [ "$status" -eq 0 ]
    local manifest="$OUT/osv/wrangle_attestation_metadata.json"
    [ -f "$manifest" ]
    [ "$(jq -r '."predicate-type"' "$manifest")" = "https://github.com/TomHennen/wrangle/attestation/scan/v1" ]
    [ "$(jq -r '.tool.name' "$manifest")" = "osv-scanner" ]
    [ "$(jq -r '.result' "$manifest")" = "clean" ]
}

@test "run.sh image dispatch: no scan manifest for an unwired tool token" {
    printf 'clean' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    [ ! -f "$OUT/mocktool/wrangle_attestation_metadata.json" ]
}

@test "run.sh image dispatch: an undeclared host GITHUB_TOKEN never reaches the container" {
    # With no catalog secret:, docker gets only the -e flags run_tool_image builds;
    # a host GITHUB_TOKEN must not be among them. The mock records what it saw.
    printf 'secret' > "$SRC/MODE"
    WRANGLE_TOOLS_DIR="$TOOLS" GITHUB_TOKEN="ghs_should_not_leak" \
        run "$RUN_SH" -s "$SRC" -o "$OUT" mocktool
    [ "$status" -eq 0 ]
    [ -z "$(cat "$OUT/mocktool/github_token_seen")" ]
}

@test "run.sh image dispatch: writes output.sarif into output_dir/<tool>/" {
    printf 'clean' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    [ -f "$OUT/mocktool/output.sarif" ]
}

@test "run.sh image dispatch: image output is owned by the runner uid" {
    printf 'clean' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    # -u "$(id -u):$(id -g)" must make /output files consumable by the runner;
    # a root-owned file here would mean the contract's ownership rule regressed.
    [ "$(stat -c '%u' "$OUT/mocktool/output.sarif")" -eq "$(id -u)" ]
}

@test "run.sh image dispatch: does not write outside output_dir/<tool>/" {
    printf 'clean' > "$SRC/MODE"
    before="$(find "$SRC" -type f | wc -l | tr -d ' ')"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    # /src is mounted read-only; confirm the source tree is untouched.
    [ "$(find "$SRC" -type f | wc -l | tr -d ' ')" -eq "$before" ]
}

@test "run.sh image dispatch: a declared secret reaches the container env" {
    # A catalog secret: maps WRANGLE_EXTRA_<NAME> into the image as <NAME>,
    # forwarded by name (not on docker's argv). Assert it actually arrives.
    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"mocktool":{"kind":"scan","image":"$MOCK_IMAGE","secret":"mock-secret"}}}
JSON
    printf 'secret' > "$SRC/MODE"
    WRANGLE_TOOLS_DIR="$TOOLS" WRANGLE_EXTRA_MOCK_SECRET="s3cr3t-value" \
        run "$RUN_SH" -s "$SRC" -o "$OUT" mocktool
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/mocktool/secret_seen")" = "s3cr3t-value" ]
}

@test "run.sh image dispatch: github-token secret reaches the container as GITHUB_TOKEN" {
    # zizmor reads GITHUB_TOKEN from the environment for its online audits (no
    # --gh-token argv). A catalog secret: github-token must therefore arrive as
    # the GITHUB_TOKEN env var inside the container, sourced from run.sh's
    # WRANGLE_EXTRA_GITHUB_TOKEN. This guards the env-bridge the adapter relies on.
    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"mocktool":{"kind":"scan","image":"$MOCK_IMAGE","secret":"github-token"}}}
JSON
    printf 'secret' > "$SRC/MODE"
    WRANGLE_TOOLS_DIR="$TOOLS" WRANGLE_EXTRA_GITHUB_TOKEN="ghs_mocktoken" \
        run "$RUN_SH" -s "$SRC" -o "$OUT" mocktool
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/mocktool/github_token_seen")" = "ghs_mocktoken" ]
}

@test "run.sh image dispatch: no network: declared -> --network none" {
    # network omitted in the catalog -> closed by default. With --network none
    # the container sees only loopback, so no non-lo interface may appear.
    printf 'netcheck' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    [ -f "$OUT/mocktool/net_ifaces" ]
    run grep -vx 'lo' "$OUT/mocktool/net_ifaces"
    [ -z "$output" ]
}

@test "run.sh image dispatch: real osv image on a clean tree -> exit 0" {
    # The locally-built osv image (setup_file) against a source tree with no
    # package manifests. osv reports no sources -> empty SARIF, exit 0. Needs
    # no network for this path. Skips when the local osv image isn't present.
    [[ -n "${OSV_IMAGE:-}" ]] \
        || skip_or_fail "local osv image (wrangle-osv:test) not built"

    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"osv":{"kind":"scan","image":"$OSV_IMAGE","network":"egress"}}}
JSON
    mkdir -p "$TOOLS/osv"
    printf 'just text, no manifests\n' > "$SRC/README.txt"
    _run_orch osv
    [ "$status" -eq 0 ]
    wrangle_assert_sarif "$OUT/osv"
    [ "$(jq '[.runs[].results[]] | length' "$OUT/osv/output.sarif")" -eq 0 ]
    # The orchestrator's shared post-run path wrote the scan/v1 manifest for osv.
    [ -f "$OUT/osv/wrangle_attestation_metadata.json" ]
    run jq -r '.tool.name' "$OUT/osv/wrangle_attestation_metadata.json"
    [ "$output" = "osv-scanner" ]
}

@test "run.sh image dispatch: real osv image on a vulnerable manifest -> exit 1" {
    # Drives the published-image entrypoint over a deliberately-vulnerable
    # go.mod (gogo/protobuf <1.3.2, CVE-2021-3121). Needs the osv.dev API, so
    # it skips offline; egress is granted by the catalog network: egress.
    [[ -n "${OSV_IMAGE:-}" ]] \
        || skip_or_fail "local osv image (wrangle-osv:test) not built"

    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"osv":{"kind":"scan","image":"$OSV_IMAGE","network":"egress"}}}
JSON
    mkdir -p "$TOOLS/osv"
    cp "$ORIG_DIR/tools/osv/testdata/vulnerable_go.mod" "$SRC/go.mod"
    _run_orch osv
    rc=$status
    # osv.dev unreachable (sandbox): no findings — nothing to assert, skip.
    if [[ ! -s "$OUT/osv/output.sarif" ]] \
        || [[ "$(jq '[.runs[].results[]] | length' "$OUT/osv/output.sarif")" -eq 0 ]]; then
        skip_or_fail "osv produced no findings (likely network-restricted)"
    fi
    [ "$rc" -eq 1 ]
    grep -q "CVE-2021-3121" "$OUT/osv/output.md"
}

# A catalog declaring mocktool as an sbom-kind image tool. The mock writes
# sbom.spdx.json and records the WRANGLE_KIND it saw.
_sbom_catalog() {
    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"mocktool":{"kind":"sbom","image":"$MOCK_IMAGE"}}}
JSON
}

@test "run.sh sbom dispatch: clean -> exit 0, sbom.spdx.json + attest manifest" {
    _sbom_catalog
    printf 'sbom' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    [ -f "$OUT/mocktool/sbom.spdx.json" ]
    [ "$(jq -r '.spdxVersion' "$OUT/mocktool/sbom.spdx.json")" = "SPDX-2.3" ]
    # sbom writes the attest manifest, never an output.md.
    [ -f "$OUT/mocktool/wrangle_attestation_metadata.json" ]
    [ "$(jq -r '."predicate-type"' "$OUT/mocktool/wrangle_attestation_metadata.json")" = "https://spdx.dev/Document" ]
    [ "$(jq -r '."result-file"' "$OUT/mocktool/wrangle_attestation_metadata.json")" = "sbom.spdx.json" ]
    [ ! -f "$OUT/mocktool/output.md" ]
}

@test "run.sh sbom dispatch: WRANGLE_KIND reaches the container" {
    _sbom_catalog
    printf 'sbom' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/mocktool/kind_seen")" = "sbom" ]
}

@test "run.sh sbom dispatch: WRANGLE_SOURCE_NAME is the source dir basename" {
    _sbom_catalog
    printf 'sbom' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/mocktool/source_name_seen")" = "$(basename "$SRC")" ]
}

@test "run.sh scan dispatch: WRANGLE_SOURCE_NAME is the source dir basename" {
    printf 'source-name' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/mocktool/source_name_seen")" = "$(basename "$SRC")" ]
}

@test "run.sh sbom dispatch: tool error -> exit 2" {
    _sbom_catalog
    printf 'sbom-error' > "$SRC/MODE"
    _run_orch mocktool
    [ "$status" -eq 2 ]
}

@test "generate_sbom: image dispatch lands SBOM + manifest at the metadata root" {
    # End-to-end: lib/generate_sbom.sh -> run.sh -> mock sbom image, then the
    # relocation out of the <tool>/ subdir the attest engine wouldn't discover.
    _sbom_catalog
    printf 'sbom' > "$SRC/MODE"
    local meta="$TMP_DIR/meta"
    WRANGLE_TOOLS_DIR="$TOOLS" run "$ORIG_DIR/lib/generate_sbom.sh" "$SRC" "$meta" mocktool
    [ "$status" -eq 0 ]
    [ -f "$meta/sbom.spdx.json" ]
    [ "$(jq -r '."predicate-type"' "$meta/wrangle_attestation_metadata.json")" = "https://spdx.dev/Document" ]
    [ "$(jq -r '."result-file"' "$meta/wrangle_attestation_metadata.json")" = "sbom.spdx.json" ]
    [ ! -d "$meta/mocktool" ]
}

@test "generate_sbom: fails closed when the dispatched tool errors" {
    # The image errors and writes no SBOM (a failed VSA gate / tool error looks
    # the same). run.sh returns 2; generate_sbom must propagate, not relocate.
    _sbom_catalog
    printf 'sbom-error' > "$SRC/MODE"
    local meta="$TMP_DIR/meta"
    WRANGLE_TOOLS_DIR="$TOOLS" run "$ORIG_DIR/lib/generate_sbom.sh" "$SRC" "$meta" mocktool
    [ "$status" -ne 0 ]
    [ ! -f "$meta/sbom.spdx.json" ]
}
