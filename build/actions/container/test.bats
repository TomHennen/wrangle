#!/usr/bin/env bats

# Structural tests for build/actions/container/action.yml.
#
# Covers input-validation hardening specific to this action that
# neither zizmor nor actionlint check directly.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
    GITHUB_OUTPUT="$(mktemp)"
    export GITHUB_OUTPUT
}

teardown() {
    rm -f "$GITHUB_OUTPUT"
}

@test "container: validate_inputs.sh exists and is executable" {
    [[ -x "$ACTION_DIR/validate_inputs.sh" ]]
}

@test "container: validate_inputs.sh disables globbing with set -f" {
    # External input flows into the script; CLAUDE.md requires set -f.
    run grep '^set -f' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml delegates input validation to validate_inputs.sh" {
    run grep 'validate_inputs.sh' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: validate_inputs.sh rejects absolute path" {
    run "$ACTION_DIR/validate_inputs.sh" "/etc" "ghcr.io" "ghcr.io/owner/img" "enabled"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"path must be relative"* ]]
}

@test "container: validate_inputs.sh rejects traversal" {
    run "$ACTION_DIR/validate_inputs.sh" "../etc" "ghcr.io" "ghcr.io/owner/img" "enabled"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"traversal"* ]]
}

@test "container: validate_inputs.sh rejects bad registry" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "BAD;REGISTRY" "ghcr.io/owner/img" "enabled"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid registry"* ]]
}

@test "container: validate_inputs.sh rejects bad imagename" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "BAD IMAGE" "enabled"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid image name"* ]]
}

@test "container: validate_inputs.sh writes path/imagename/shortname to GITHUB_OUTPUT" {
    run "$ACTION_DIR/validate_inputs.sh" "pkg/foo" "ghcr.io" "ghcr.io/owner/img" "enabled"
    [[ "$status" -eq 0 ]]
    grep -q '^path=pkg/foo$' "$GITHUB_OUTPUT"
    grep -q '^imagename=ghcr.io/owner/img$' "$GITHUB_OUTPUT"
    grep -q '^shortname=pkg_foo$' "$GITHUB_OUTPUT"
}

# --- Cache gating (SLSA L3 isolation, #224 / SLSA_L3_AUDIT.md Finding 2) ---

@test "container: validate_inputs.sh accepts cache=enabled and cache=disabled" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "ghcr.io/owner/img" "enabled"
    [[ "$status" -eq 0 ]]
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "ghcr.io/owner/img" "disabled"
    [[ "$status" -eq 0 ]]
}

@test "container: validate_inputs.sh rejects an invalid cache value" {
    # A typo must fail loudly — silently leaving the cache on would
    # downgrade a release build from Build L3 to Build L2.
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "ghcr.io/owner/img" "disabeld"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid cache value"* ]]
}

@test "container: validate_inputs.sh rejects a missing cache argument" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "ghcr.io/owner/img"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "container: action.yml exposes a cache input" {
    run grep -E '^  cache:' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml passes cache to validate_inputs.sh" {
    run grep -E 'validate_inputs.sh.*INPUT_CACHE' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml gates cache-from/cache-to on the cache input" {
    # Pin the full expression — operator and operands. A loose
    # 'mentions inputs.cache' regex would still pass if the condition
    # were inverted (!= instead of ==), which turns caching ON for
    # release builds: the exact Build L3 downgrade this gating prevents.
    run grep -F "cache-from: \${{ inputs.cache == 'enabled' && 'type=gha' || '' }}" "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    run grep -F "cache-to: \${{ inputs.cache == 'enabled' && 'type=gha,mode=max' || '' }}" "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # The unconditional type=gha cache config must be gone.
    run grep -E '^[[:space:]]+cache-from:[[:space:]]*type=gha[[:space:]]*$' "$ACTION_DIR/action.yml"
    [[ "$status" -ne 0 ]]
}

@test "container: build job needs gate so it can read should-release" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$wf\" | grep -E 'needs:.*gate'"
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow disables cache for release builds" {
    # The composite's cache input must be driven by should-release:
    # 'disabled' on release, 'enabled' otherwise.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "grep -E \"cache:.*should-release.*'disabled'.*'enabled'\" \"$wf\""
    [[ "$status" -eq 0 ]]
}

# --- Unified metadata layout assertions (#150) ---

@test "container: action.yml writes SBOM under metadata/container/<shortname>/" {
    run grep 'metadata/container/' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml exposes metadata-dir output" {
    run grep -E '^[[:space:]]+metadata-dir:' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml exposes shortname output" {
    run grep -E '^[[:space:]]+shortname:' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml uploads container-metadata-<shortname> artifact" {
    run grep 'container-metadata-' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # Old name must not linger
    run grep 'container-build-results' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 1 ]]
}

@test "container: action.yml prepares metadata dir before SBOM extraction and upload" {
    # The standalone Prepare-metadata step must run BEFORE Extract-SBOM and
    # BEFORE the upload step, so the upload's path resolves to a real dir
    # even on `if: always()` after an earlier-step failure.
    run bash -c "awk '/Prepare metadata directory/{p=NR} /Extract SBOM from built image/{s=NR} /actions\\/upload-artifact/{u=NR} END{exit !(p && s && u && p<s && p<u)}' \"$ACTION_DIR/action.yml\""
    [[ "$status" -eq 0 ]]
}

@test "container: upload-artifact path uses meta_dir output, not get_sbom output" {
    # `meta_dir` always runs (no upstream dependency on the build); `get_sbom`
    # depends on a successful build. The upload must reference meta_dir or
    # `if: always()` could resolve to an empty path on failure.
    run grep -E 'path:[[:space:]]*\$\{\{[[:space:]]*steps\.meta_dir\.outputs\.metadata-dir' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    run grep -E 'path:[[:space:]]*\$\{\{[[:space:]]*steps\.get_sbom\.outputs\.metadata-dir' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 1 ]]
}

@test "container: composite metadata-dir output sources from meta_dir step" {
    # The composite's metadata-dir output must reference meta_dir (always
    # runs), not get_sbom (depends on build success).
    run grep -E '^[[:space:]]+value:[[:space:]]*\$\{\{[[:space:]]*steps\.meta_dir\.outputs\.metadata-dir' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow exposes metadata-artifact-name output" {
    run grep 'metadata-artifact-name:' "$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow has gate job calling release_gate" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^  gate:' "$wf"
    [[ "$status" -eq 0 ]]
    run grep -E 'TomHennen/wrangle/actions/release_gate' "$wf"
    [[ "$status" -eq 0 ]]
}

@test "container: provenance job is gated on release-gate output" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  provenance:/,/^[a-z]/p' \"$wf\" | grep -E \"if:.*should-release\""
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow exposes release-events input and should-release output" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^      release-events:' "$wf"
    [[ "$status" -eq 0 ]]
    run grep -E '^      should-release:' "$wf"
    [[ "$status" -eq 0 ]]
}

# --- Verify-image (#176) ---

@test "container: reusable workflow has verify job calling cosign verify-attestation" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^  verify:' "$wf"
    [[ "$status" -eq 0 ]]
    run grep 'cosign verify-attestation' "$wf"
    [[ "$status" -eq 0 ]]
    run grep -E 'sigstore/cosign-installer@[0-9a-f]{40}' "$wf"
    [[ "$status" -eq 0 ]]
}

@test "container: verify job is gated on should-release AND verify-image" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$wf\" | grep -E \"if:.*should-release.*verify-image\""
    [[ "$status" -eq 0 ]]
}

@test "container: workflow exposes verify-image input (default true)" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^      verify-image:' "$wf"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^      verify-image:/,/^      [a-z]/p' \"$wf\" | grep -E 'default:[[:space:]]*true'"
    [[ "$status" -eq 0 ]]
}

@test "container: verify job pins SLSA generator cert identity to the same tag as provenance job" {
    # The cert identity in the verify command MUST point at the same SLSA
    # generator tag the provenance: job invokes. A lockstep mismatch would
    # break verification on every run.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    local generator_tag verify_tag
    generator_tag="$(grep -oE 'generator_container_slsa3\.yml@v[0-9]+\.[0-9]+\.[0-9]+' "$wf" | head -1 | sed 's/.*@//')"
    verify_tag="$(grep -oE 'generator_container_slsa3\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+' "$wf" | head -1 | sed 's@.*refs/tags/@@')"
    [[ -n "$generator_tag" ]]
    [[ -n "$verify_tag" ]]
    [[ "$generator_tag" == "$verify_tag" ]]
}

@test "container: verify job depends on provenance" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$wf\" | grep -E 'needs:.*provenance'"
    [[ "$status" -eq 0 ]]
}

@test "container: verify job pins certificate-github-workflow-repository to the calling repo" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep 'certificate-github-workflow-repository' "$wf"
    [[ "$status" -eq 0 ]]
    run grep 'github.repository' "$wf"
    [[ "$status" -eq 0 ]]
}
