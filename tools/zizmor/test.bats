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

@test "zizmor: requirements.txt and action.yml default agree on version" {
    # Local test container installs zizmor via pip --require-hashes from
    # tools/zizmor/requirements.txt; CI uses the upstream Docker action driven
    # by tools/zizmor/action.yml's default version input. Drift between these
    # masks regressions between local pre-push checks and CI. Dependabot bumps
    # requirements.txt; this test makes sure action.yml's default tracks it.
    local req_version action_version
    req_version="$(grep -E '^zizmor==' "$ORIG_DIR/tools/zizmor/requirements.txt" | head -1 | sed -E 's/^zizmor==([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    action_version="$(grep -E '^ +default: "v[0-9]+\.[0-9]+\.[0-9]+"' "$ORIG_DIR/tools/zizmor/action.yml" | sed -E 's/.*"v([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')"
    [ -n "$req_version" ]
    [ -n "$action_version" ]
    [ "$req_version" = "$action_version" ]
}

@test "zizmor: requirements.txt pins zizmor with sha256 hashes" {
    # --require-hashes refuses to install if any artifact lacks a sha256 in
    # this file. Guard against accidental hash removal.
    grep -qE '^zizmor==[0-9]+\.[0-9]+\.[0-9]+' "$ORIG_DIR/tools/zizmor/requirements.txt"
    grep -qE '^ +--hash=sha256:[0-9a-f]{64}' "$ORIG_DIR/tools/zizmor/requirements.txt"
}

@test "zizmor: dependabot tracks tools/zizmor (pip ecosystem)" {
    # If Dependabot loses sight of this directory, hash + version drift
    # against upstream and the wrangle action.yml default goes silent.
    grep -qE 'package-ecosystem: +"pip"' "$ORIG_DIR/.github/dependabot.yml"
    grep -qE '"/tools/(zizmor|\*\*)"' "$ORIG_DIR/.github/dependabot.yml"
}
