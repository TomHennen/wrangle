#!/usr/bin/env bats

# Structural tests for actions/scan/action.yml.
#
# Covers wiring that neither zizmor nor actionlint check:
# SARIF upload step presence and correct category names, artifact
# upload presence, and references to local tool actions. These catch
# the regression "someone removed the OSV SARIF upload step" which
# would otherwise ship silently.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
}

@test "scan: has upload-sarif step for osv" {
    run grep -A2 'Upload OSV SARIF' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"upload-sarif"* ]]
}

@test "scan: osv SARIF has correct category (wrangle/osv)" {
    run grep 'category: wrangle/osv' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: has upload-sarif step for scorecard" {
    run grep -A2 'Upload Scorecard SARIF' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"upload-sarif"* ]]
}

@test "scan: scorecard SARIF has correct category (wrangle/scorecard)" {
    run grep 'category: wrangle/scorecard' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: has upload-artifact step" {
    run grep 'upload-artifact' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: artifact name is wrangle-scan-results" {
    run grep 'name: wrangle-scan-results' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: references zizmor via local path" {
    run grep 'uses: ./tools/zizmor' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: references scorecard via local path" {
    run grep 'uses: ./tools/scorecard' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}
