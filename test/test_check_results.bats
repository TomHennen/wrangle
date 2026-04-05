#!/usr/bin/env bats

# Tests for lib/check_results.sh

setup() {
    export TEST_DIR="$(mktemp -d)"
    export ORIG_DIR="$(pwd)"
    export METADATA="$TEST_DIR/metadata"
    mkdir -p "$METADATA"
}

teardown() {
    cd "$ORIG_DIR"
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
