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

@test "scan: artifact name is the artifact-name input (caller-supplied)" {
    # The scan job no longer owns a fixed name — a build workflow passes a
    # per-build name it folds into the unified metadata artifact; the
    # standalone scan workflow passes `scan` (or `scan-<sn>` for a subdir).
    run grep 'name: ${{ inputs.artifact-name }}' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: standalone check_source_change scans the root and uploads clean 'scan'" {
    # Root build → empty shortname → the artifact name drops the suffix
    # entirely (not the old 'scan-_').
    local wf="$ACTION_DIR/../../.github/workflows/check_source_change.yml"
    run grep -E '^[[:space:]]+artifact-name: scan$' "$wf"
    [ "$status" -eq 0 ]
    run grep -E 'artifact-name: scan-_' "$wf"
    [ "$status" -ne 0 ]
}

@test "scan: artifact-name defaults to wrangle-scan-results for direct callers" {
    run bash -c "grep -A12 '^  artifact-name:' '$ACTION_DIR/action.yml' | grep -m1 'default:'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'default: "wrangle-scan-results"'* ]]
}

@test "scan: optional checkout is opt-in, gated on the checkout input" {
    run grep -F "if: inputs.checkout == 'true'" "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    run grep -F 'persist-credentials: false' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    run grep -F 'ref: ${{ inputs.ref }}' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: checkout defaults to false so self-checkout callers don't double-checkout" {
    run bash -c "grep -A10 '^  checkout:' '$ACTION_DIR/action.yml' | grep -m1 'default:'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'default: "false"'* ]]
}

@test "scan: checkout step precedes the tool steps (source exists before scanning)" {
    # The tools scan $GITHUB_WORKSPACE, so an opt-in checkout must run before
    # the wrangle setup + tool steps.
    checkout_line="$(grep -n 'Check out source' "$ACTION_DIR/action.yml" | head -1 | cut -d: -f1)"
    setup_line="$(grep -n 'Set up wrangle' "$ACTION_DIR/action.yml" | head -1 | cut -d: -f1)"
    [ -n "$checkout_line" ] && [ -n "$setup_line" ]
    [ "$checkout_line" -lt "$setup_line" ]
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
    run grep 'default: "osv zizmor scorecard:info dependency-review wrangle-lint"' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: does not plumb per-tool dependency-review config (deferred to #221)" {
    # Per-tool config is intentionally not exposed through actions/scan —
    # see #221. The Dependency Review step uses the wrapper's defaults.
    run grep 'dependency-review-fail-on-severity' "$ACTION_DIR/action.yml"
    [ "$status" -ne 0 ]
    run grep 'dependency-review-comment-summary-in-pr' "$ACTION_DIR/action.yml"
    [ "$status" -ne 0 ]
}

@test "scan: go-cache defaults off so adopters pay no surprise cache quota" {
    run grep -c '^  go-cache:' "$ACTION_DIR/action.yml"
    [[ "$output" == "1" ]]
    # The first default: after the go-cache: key is its own (go-cache is the
    # last input). Empty string = caching off unless a caller opts in.
    run bash -c "grep -A20 '^  go-cache:' '$ACTION_DIR/action.yml' | grep -m1 'default:'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'default: ""'* ]]
}

@test "scan: Go cache steps are gated on go-cache (no staging/setup by default)" {
    # Ungated, these would stage a file + cache ~3GB on every run.
    run grep -A1 'Stage Go cache key' "$ACTION_DIR/action.yml"
    [[ "$output" == *"inputs.go-cache == 'enabled'"* ]]
    run grep -A1 'Set up Go with module' "$ACTION_DIR/action.yml"
    [[ "$output" == *"inputs.go-cache == 'enabled'"* ]]
}

@test "scan: Go cache key file is not a lockfile name (osv scans the workspace)" {
    # A file named go.sum/go.mod here would be scanned as the adopter's own,
    # reporting wrangle's tool deps as their findings.
    run grep 'cache-dependency-path:' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" != *"go.sum"* ]]
    [[ "$output" != *"go.mod"* ]]
}
