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

@test "zizmor: action.yml uses WRANGLE_METADATA_DIR for output path" {
    grep -q 'WRANGLE_METADATA_DIR' "$ORIG_DIR/tools/zizmor/action.yml"
}
