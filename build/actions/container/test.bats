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
    run "$ACTION_DIR/validate_inputs.sh" "/etc" "ghcr.io" "ghcr.io/owner/img"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"path must be relative"* ]]
}

@test "container: validate_inputs.sh rejects traversal" {
    run "$ACTION_DIR/validate_inputs.sh" "../etc" "ghcr.io" "ghcr.io/owner/img"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"traversal"* ]]
}

@test "container: validate_inputs.sh rejects bad registry" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "BAD;REGISTRY" "ghcr.io/owner/img"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid registry"* ]]
}

@test "container: validate_inputs.sh rejects bad imagename" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "BAD IMAGE"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid image name"* ]]
}

@test "container: validate_inputs.sh writes path/imagename/shortname to GITHUB_OUTPUT" {
    run "$ACTION_DIR/validate_inputs.sh" "pkg/foo" "ghcr.io" "ghcr.io/owner/img"
    [[ "$status" -eq 0 ]]
    grep -q '^path=pkg/foo$' "$GITHUB_OUTPUT"
    grep -q '^imagename=ghcr.io/owner/img$' "$GITHUB_OUTPUT"
    grep -q '^shortname=pkg_foo$' "$GITHUB_OUTPUT"
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
