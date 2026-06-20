#!/usr/bin/env bats

# Tests for lib/check_results.sh

setup() {
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR
    ORIG_DIR="$(pwd)"
    export ORIG_DIR
    export METADATA="$TEST_DIR/metadata"
    mkdir -p "$METADATA"
}

teardown() {
    cd "$ORIG_DIR" || exit 1
    rm -rf "$TEST_DIR"
}

# Helper: create SARIF with N findings for a tool
create_sarif() {
    local tool="$1"
    local count="$2"
    mkdir -p "$METADATA/$tool"
    local results="[]"
    if [[ "$count" -gt 0 ]]; then
        results="$(jq -n --argjson n "$count" '[range($n) | {"ruleId": "TEST-\(.)","message":{"text":"finding"}}]')"
    fi
    jq -n --argjson r "$results" \
        '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"test"}},"results":$r}]}' \
        > "$METADATA/$tool/output.sarif"
}

# --- Basic usage ---

@test "check_results: requires at least 2 arguments" {
    run "$ORIG_DIR/lib/check_results.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]
}

@test "check_results: requires metadata_dir argument" {
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA"
    [ "$status" -eq 2 ]
}

@test "check_results: fails on nonexistent metadata directory" {
    run "$ORIG_DIR/lib/check_results.sh" "$TEST_DIR/nonexistent" "osv"
    [ "$status" -eq 2 ]
}

# --- Policy parsing ---

@test "check_results: default policy is fail" {
    create_sarif "osv" 1
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "osv"
    [ "$status" -eq 1 ]
    [[ "$output" == *"osv reported 1 finding(s)"* ]]
}

@test "check_results: explicit :fail policy fails on findings" {
    create_sarif "osv" 2
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "osv:fail"
    [ "$status" -eq 1 ]
    [[ "$output" == *"osv reported 2 finding(s)"* ]]
}

@test "check_results: :info policy does not fail on findings" {
    create_sarif "scorecard" 5
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "scorecard:info"
    [ "$status" -eq 0 ]
    [[ "$output" == *"informational"* ]]
}

@test "check_results: invalid policy causes failure" {
    create_sarif "osv" 0
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "osv:warn"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid policy"* ]]
}

# --- Finding detection ---

@test "check_results: passes when no findings" {
    create_sarif "osv" 0
    create_sarif "zizmor" 0
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "osv" "zizmor"
    [ "$status" -eq 0 ]
}

@test "check_results: fails when any fail-policy tool has findings" {
    create_sarif "osv" 0
    create_sarif "zizmor" 3
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "osv" "zizmor"
    [ "$status" -eq 1 ]
    [[ "$output" == *"zizmor reported 3 finding(s)"* ]]
}

@test "check_results: mixed fail and info policies" {
    create_sarif "osv" 0
    create_sarif "zizmor" 0
    create_sarif "scorecard" 10
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "osv" "zizmor" "scorecard:info"
    [ "$status" -eq 0 ]
    [[ "$output" == *"informational"* ]]
}

@test "check_results: missing SARIF is not an error (tool may have been skipped)" {
    # scorecard skipped on PRs — no directory or SARIF
    create_sarif "osv" 0
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "osv" "scorecard:info"
    [ "$status" -eq 0 ]
}

# A :fail tool with no SARIF (e.g. scorecard, which produces JSON not SARIF)
# must not crash or block — it contributes no findings here. Score-threshold
# gating is the policy/tenet work (#497), not this gate.
@test "check_results: missing SARIF with fail policy is not an error" {
    create_sarif "osv" 0
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "osv" "scorecard:fail"
    [ "$status" -eq 0 ]
}

@test "check_results: malformed SARIF with fail policy causes failure" {
    mkdir -p "$METADATA/bad"
    echo "not json" > "$METADATA/bad/output.sarif"
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid SARIF"* ]]
}

@test "check_results: malformed SARIF with info policy does not fail" {
    mkdir -p "$METADATA/bad"
    echo "not json" > "$METADATA/bad/output.sarif"
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "bad:info"
    [ "$status" -eq 0 ]
}

# --- Tool-error marker (issue #222) ---
#
# Action-pattern wrappers write a per-tool `error` marker file when the
# upstream step fails in a way that does NOT correspond to "found issues".
# check_results.sh must treat the marker as fail-closed for :fail policy,
# and as informational-only for :info policy. The marker must take
# precedence over the SARIF count so a fallback empty SARIF (0 results)
# cannot mask the error.

@test "check_results: error marker on :fail tool exits 1" {
    mkdir -p "$METADATA/depreview"
    printf 'API unavailable\n' > "$METADATA/depreview/error"
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "depreview"
    [ "$status" -eq 1 ]
    [[ "$output" == *"depreview errored"* ]]
    [[ "$output" == *"API unavailable"* ]]
}

@test "check_results: error marker on explicit :fail tool exits 1" {
    mkdir -p "$METADATA/depreview"
    printf 'API unavailable\n' > "$METADATA/depreview/error"
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "depreview:fail"
    [ "$status" -eq 1 ]
    [[ "$output" == *"depreview errored"* ]]
}

@test "check_results: error marker on :info tool does not fail" {
    mkdir -p "$METADATA/scorecard"
    printf 'scorecard transient failure\n' > "$METADATA/scorecard/error"
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "scorecard:info"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scorecard errored"* ]]
    [[ "$output" == *"informational"* ]]
}

@test "check_results: error marker wins over empty SARIF (no double-counting)" {
    # The wrapper synthesises an empty SARIF as a fallback so downstream
    # steps (Code Scanning upload, step summary) always have a file to
    # read. check_results.sh must NOT read the empty SARIF as "0 findings"
    # and pass — it must see the marker and fail.
    mkdir -p "$METADATA/zizmor"
    printf 'zizmor crashed\n' > "$METADATA/zizmor/error"
    jq -n '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"zizmor"}}, "results":[]}]}' \
        > "$METADATA/zizmor/output.sarif"
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "zizmor"
    [ "$status" -eq 1 ]
    [[ "$output" == *"zizmor errored"* ]]
    # We did not silently fall back to a finding count.
    [[ "$output" != *"finding(s)"* ]]
}

@test "check_results: error marker affects only listed tools" {
    # Marker for a tool not present in the args is ignored.
    mkdir -p "$METADATA/other"
    printf 'noise\n' > "$METADATA/other/error"
    create_sarif "osv" 0
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "osv"
    [ "$status" -eq 0 ]
}

@test "check_results: empty error marker still fails closed" {
    # A zero-byte marker should still trigger failure with a generic
    # message — never accidentally read as "no error".
    mkdir -p "$METADATA/depreview"
    : > "$METADATA/depreview/error"
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "depreview"
    [ "$status" -eq 1 ]
    [[ "$output" == *"depreview errored"* ]]
}

@test "check_results: error marker + findings still exits 1 with error message" {
    # If both findings and error marker exist (shouldn't happen, but be
    # defensive), the marker takes precedence — fail-closed is correct.
    mkdir -p "$METADATA/zizmor"
    printf 'zizmor crashed\n' > "$METADATA/zizmor/error"
    create_sarif "zizmor" 3
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "zizmor"
    [ "$status" -eq 1 ]
    [[ "$output" == *"zizmor errored"* ]]
}

@test "check_results: no error marker and no findings still passes" {
    # Regression guard: the existing happy path is unchanged.
    create_sarif "zizmor" 0
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "zizmor"
    [ "$status" -eq 0 ]
}

@test "check_results: error marker contents are sanitised before logging" {
    # The marker contract (docs/SPEC.md, Two Tool Patterns) is "contents
    # are untrusted, will be sanitised" — wrappers can interpolate raw
    # upstream output without worrying about HTML/markdown injection
    # into the Actions log surface.
    mkdir -p "$METADATA/depreview"
    printf '<script>alert(1)</script>genuine error\n' > "$METADATA/depreview/error"
    run "$ORIG_DIR/lib/check_results.sh" "$METADATA" "depreview"
    [ "$status" -eq 1 ]
    [[ "$output" != *"<script>"* ]]
    [[ "$output" == *"genuine error"* ]]
}
