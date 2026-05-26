#!/usr/bin/env bats

# Tests for lib/log_findings.sh

setup() {
    export TEST_DIR="$(mktemp -d)"
    export ORIG_DIR="$(pwd)"
    export SCRIPT="$ORIG_DIR/lib/log_findings.sh"
    export METADATA="$TEST_DIR/metadata"
    mkdir -p "$METADATA"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

@test "log_findings: requires metadata_dir argument" {
    run "$SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "log_findings: silent on nonexistent metadata directory" {
    # The action invokes us unconditionally — missing metadata is fine.
    run "$SCRIPT" "$TEST_DIR/missing"

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "log_findings: empty metadata directory produces no output" {
    run "$SCRIPT" "$METADATA"

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "log_findings: tool with no SARIF is silently skipped" {
    mkdir -p "$METADATA/scorecard"
    run "$SCRIPT" "$METADATA"

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "log_findings: tool with empty findings produces no log lines" {
    mkdir -p "$METADATA/clean"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$METADATA/clean/output.sarif"

    run "$SCRIPT" "$METADATA"

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "log_findings: emits one line per finding with tool, ruleId, location, message" {
    mkdir -p "$METADATA/zizmor"
    cp "$ORIG_DIR/test/fixtures/findings.sarif" "$METADATA/zizmor/output.sarif"

    run "$SCRIPT" "$METADATA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"wrangle: zizmor[1/2] TEST-001 src/main.c:10"* ]]
    [[ "$output" == *"wrangle: zizmor[2/2] TEST-001 src/utils.c:42"* ]]
    [[ "$output" == *"A test vulnerability was found"* ]]
    [[ "$output" == *"Another test finding"* ]]
}

@test "log_findings: emits exactly N lines for N findings" {
    mkdir -p "$METADATA/zizmor"
    cp "$ORIG_DIR/test/fixtures/findings.sarif" "$METADATA/zizmor/output.sarif"

    line_count=$("$SCRIPT" "$METADATA" | wc -l | tr -d ' ')

    [[ "$line_count" -eq 2 ]]
}

@test "log_findings: malformed SARIF is silently skipped (check_results gates)" {
    mkdir -p "$METADATA/bad"
    cp "$ORIG_DIR/test/fixtures/malformed.sarif" "$METADATA/bad/output.sarif"

    run "$SCRIPT" "$METADATA"

    # Script must not fail — check_results.sh is the failure gate. We
    # stay silent so it doesn't double-report on the same bad SARIF.
    [ "$status" -eq 0 ]
    [[ "$output" != *"bad["* ]]
}

@test "log_findings: not-json SARIF is silently skipped" {
    mkdir -p "$METADATA/bad"
    echo "not json" > "$METADATA/bad/output.sarif"

    run "$SCRIPT" "$METADATA"

    [ "$status" -eq 0 ]
    [[ "$output" != *"bad["* ]]
}

@test "log_findings: HTML tags in messages are stripped" {
    mkdir -p "$METADATA/injected"
    cp "$ORIG_DIR/test/fixtures/injection.sarif" "$METADATA/injected/output.sarif"

    run "$SCRIPT" "$METADATA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"INJECT-001"* ]]
    [[ "$output" != *"<img"* ]]
    [[ "$output" != *"<script>"* ]]
    [[ "$output" != *"onerror"* ]]
}

@test "log_findings: long messages are truncated" {
    export WRANGLE_MAX_FINDING_MESSAGE=20
    mkdir -p "$METADATA/zizmor"
    # Build SARIF with a long message
    jq -n '{
      "version":"2.1.0",
      "runs":[{
        "tool":{"driver":{"name":"zizmor"}},
        "results":[{
          "ruleId":"long-msg",
          "message":{"text":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
          "locations":[{"physicalLocation":{"artifactLocation":{"uri":"x.yml"},"region":{"startLine":1}}}]
        }]
      }]
    }' > "$METADATA/zizmor/output.sarif"

    run env WRANGLE_MAX_FINDING_MESSAGE=20 "$SCRIPT" "$METADATA"

    [ "$status" -eq 0 ]
    # Pull the trailing message portion (after " -- ") and verify it's <= 20 chars.
    msg="${output##* -- }"
    [[ ${#msg} -le 20 ]]
}

@test "log_findings: iterates tools deterministically (sorted)" {
    mkdir -p "$METADATA/b-tool" "$METADATA/a-tool"
    cp "$ORIG_DIR/test/fixtures/findings.sarif" "$METADATA/b-tool/output.sarif"
    cp "$ORIG_DIR/test/fixtures/findings.sarif" "$METADATA/a-tool/output.sarif"

    output="$("$SCRIPT" "$METADATA")"

    # a-tool lines must appear before b-tool lines
    a_line=$(printf '%s\n' "$output" | grep -n 'a-tool\[' | head -1 | cut -d: -f1)
    b_line=$(printf '%s\n' "$output" | grep -n 'b-tool\[' | head -1 | cut -d: -f1)
    [[ "$a_line" -lt "$b_line" ]]
}

@test "log_findings: finding without location uses defaults" {
    mkdir -p "$METADATA/no-loc"
    jq -n '{
      "version":"2.1.0",
      "runs":[{
        "tool":{"driver":{"name":"no-loc"}},
        "results":[{"ruleId":"R1","message":{"text":"no location info"}}]
      }]
    }' > "$METADATA/no-loc/output.sarif"

    run "$SCRIPT" "$METADATA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"no-loc[1/1] R1 unknown:?"* ]]
}

@test "log_findings: finding without ruleId uses unknown-rule" {
    mkdir -p "$METADATA/no-rule"
    jq -n '{
      "version":"2.1.0",
      "runs":[{
        "tool":{"driver":{"name":"no-rule"}},
        "results":[{"message":{"text":"no rule id"},
          "locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.yml"},"region":{"startLine":3}}}]}]
      }]
    }' > "$METADATA/no-rule/output.sarif"

    run "$SCRIPT" "$METADATA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"no-rule[1/1] unknown-rule a.yml:3"* ]]
}
