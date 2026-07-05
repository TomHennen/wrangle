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

@test "scan: does not upload scorecard SARIF (score carried by attestation)" {
    run grep 'category: wrangle/scorecard' "$ACTION_DIR/action.yml"
    [ "$status" -ne 0 ]
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

@test "scan: artifact-name defaults to the convention name for direct callers" {
    run bash -c "grep -A12 '^  artifact-name:' '$ACTION_DIR/action.yml' | grep -m1 'default:'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'default: "scan"'* ]]
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

@test "scan: retention-days defaults empty so the standalone deliverable keeps repo-default retention" {
    # The upload step is dual-purpose: a build caller passes "1" to mark the
    # folded transient, but the standalone scan artifact is the deliverable and
    # must not be short-retained. An empty default leaves the repo default.
    run bash -c "grep -A8 '^  retention-days:' '$ACTION_DIR/action.yml' | grep -m1 'default:'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'default: ""'* ]]
    run grep -F 'retention-days: ${{ inputs.retention-days }}' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: build workflows short-retain the folded scan transient" {
    # The standalone callers (check_source_change, build_shell) must NOT pass
    # retention-days; the build workflows that fold scan into metadata must.
    local wf_dir="$ACTION_DIR/../../.github/workflows"
    for t in go npm python container; do
        run grep -F 'retention-days: 1' "$wf_dir/build_and_publish_$t.yml"
        [ "$status" -eq 0 ]
    done
    run grep -F 'retention-days' "$wf_dir/check_source_change.yml"
    [ "$status" -ne 0 ]
}

@test "scan: checkout step precedes the tool steps (source exists before scanning)" {
    # The tools scan $GITHUB_WORKSPACE, so an opt-in checkout must run before
    # the wrangle setup + tool steps.
    checkout_line="$(grep -n 'Check out source' "$ACTION_DIR/action.yml" | head -1 | cut -d: -f1)"
    setup_line="$(grep -n 'Set up wrangle' "$ACTION_DIR/action.yml" | head -1 | cut -d: -f1)"
    [ -n "$checkout_line" ] && [ -n "$setup_line" ]
    [ "$checkout_line" -lt "$setup_line" ]
}

@test "scan: has upload-sarif step for zizmor" {
    run grep -A2 'Upload Zizmor SARIF' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"upload-sarif"* ]]
}

@test "scan: zizmor SARIF has correct category (wrangle/zizmor)" {
    run grep 'category: wrangle/zizmor' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "scan: zizmor SARIF upload is gated on zizmor being in the tools input" {
    run grep -A1 'Upload Zizmor SARIF' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"contains(inputs.tools, 'zizmor')"* ]]
}

@test "scan: does not wire zizmor as a uses: action step (runs via the image path)" {
    run grep 'uses:.*tools/zizmor' "$ACTION_DIR/action.yml"
    [ "$status" -ne 0 ]
}

@test "scan: forwards the github-token to run.sh as WRANGLE_EXTRA_GITHUB_TOKEN" {
    # run.sh hands this name-only to any tool that declares secret: github-token
    # (zizmor's online audits). The input defaults to the workflow token.
    run grep -F 'WRANGLE_EXTRA_GITHUB_TOKEN: ${{ inputs.github-token }}' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    run bash -c "grep -A6 '^  github-token:' '$ACTION_DIR/action.yml' | grep -m1 'default:'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'default: ${{ github.token }}'* ]]
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
