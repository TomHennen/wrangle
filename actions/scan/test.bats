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

@test "scan: osv SARIF upload is gated on osv being in the tools input" {
    run grep -A1 'Upload OSV SARIF' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"contains(inputs.tools, 'osv')"* ]]
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

@test "scan: scorecard SARIF upload is gated on scorecard being in the tools input" {
    run grep -A1 'Upload Scorecard SARIF' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"contains(inputs.tools, 'scorecard')"* ]]
}

@test "scan: has upload-artifact step" {
    run grep 'upload-artifact' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: artifact name is wrangle-scan-results" {
    run grep 'name: wrangle-scan-results' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: references zizmor action" {
    run grep 'uses:.*tools/zizmor' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: references scorecard action" {
    run grep 'uses:.*tools/scorecard' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: references dependency-review action" {
    run grep 'uses:.*tools/dependency-review' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: dependency-review step is gated on pull_request event" {
    # The upstream action requires github.event.pull_request.base.sha /
    # head.sha — running it on push events errors out.
    run grep -B1 -A2 'Dependency Review' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"github.event_name == 'pull_request'"* ]]
}

@test "scan: dependency-review step is gated on dependency-review being in the tools input" {
    run grep -A2 '^    - name: Dependency Review$' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"contains(inputs.tools, 'dependency-review')"* ]]
}

@test "scan: has upload-sarif step for dependency-review" {
    run grep -A2 'Upload Dependency Review SARIF' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"upload-sarif"* ]]
}

@test "scan: dependency-review SARIF has correct category (wrangle/dependency-review)" {
    run grep 'category: wrangle/dependency-review' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: dependency-review SARIF upload is gated on dependency-review being in the tools input and on pull_request" {
    run grep -A1 'Upload Dependency Review SARIF' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"contains(inputs.tools, 'dependency-review')"* ]]
    [[ "$output" == *"github.event_name == 'pull_request'"* ]]
}

@test "scan: default tools input includes dependency-review" {
    run grep 'default: "osv zizmor scorecard:info dependency-review"' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}
