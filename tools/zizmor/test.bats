#!/usr/bin/env bats

# Tests for tools/zizmor/ (action pattern)
#
# Action-pattern tools wrap an upstream GitHub Action, so there is no
# install.sh or adapter.sh to unit-test. These tests validate the
# action.yml structure and that supporting files are correct.
#
# Full integration testing happens in CI when the scan action invokes
# tools/zizmor/action.yml against the wrangle repo itself (dogfooding).

setup() {
    export ORIG_DIR="$(pwd)"
}

@test "zizmor: action.yml exists and is valid YAML" {
    [ -f "$ORIG_DIR/tools/zizmor/action.yml" ]
}

@test "zizmor: action.yml pins upstream action to SHA" {
    grep -q 'zizmorcore/zizmor-action@[0-9a-f]\{40\}' "$ORIG_DIR/tools/zizmor/action.yml"
}

@test "zizmor: action.yml has version input" {
    grep -q 'version:' "$ORIG_DIR/tools/zizmor/action.yml"
}

@test "zizmor: no install.sh exists (action pattern, not adapter)" {
    [ ! -f "$ORIG_DIR/tools/zizmor/install.sh" ]
}

@test "zizmor: no adapter.sh exists (action pattern, not adapter)" {
    [ ! -f "$ORIG_DIR/tools/zizmor/adapter.sh" ]
}

@test "zizmor: action.yml sets advanced-security to true" {
    # advanced-security: true is required for the upstream action to produce
    # SARIF output. See issue #109 and #114.
    grep -q 'advanced-security: true' "$ORIG_DIR/tools/zizmor/action.yml"
}

@test "zizmor: action.yml writes to wrangle metadata directory" {
    grep -q '\.wrangle/metadata/zizmor' "$ORIG_DIR/tools/zizmor/action.yml"
}

@test "zizmor: test/Dockerfile pins ZIZMOR_VERSION" {
    # The local test container installs zizmor from a pinned version with
    # checksum verification — mirrors the CI install path (the upstream
    # Docker action). A version bump here must include matching sha256
    # checksums for both architectures in the same commit.
    grep -q '^ARG ZIZMOR_VERSION=[0-9]\+\.[0-9]\+\.[0-9]\+' "$ORIG_DIR/test/Dockerfile"
    grep -q '^ARG ZIZMOR_CHECKSUM_ARM64=[0-9a-f]\{64\}' "$ORIG_DIR/test/Dockerfile"
    grep -q '^ARG ZIZMOR_CHECKSUM_AMD64=[0-9a-f]\{64\}' "$ORIG_DIR/test/Dockerfile"
}
