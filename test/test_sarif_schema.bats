#!/usr/bin/env bats

# Tests that validate SARIF fixture files are well-formed.
# Uses jq for structural validation (full JSON Schema validation
# requires a dedicated tool and is done in CI).

setup() {
    export FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures"
}

@test "sarif: empty.sarif is valid JSON" {
    run jq empty "$FIXTURES_DIR/empty.sarif"
    [ "$status" -eq 0 ]
}

@test "sarif: empty.sarif has version 2.1.0" {
    result=$(jq -r '.version' "$FIXTURES_DIR/empty.sarif")
    [ "$result" = "2.1.0" ]
}

@test "sarif: empty.sarif has runs array" {
    result=$(jq -r '.runs | type' "$FIXTURES_DIR/empty.sarif")
    [ "$result" = "array" ]
}

@test "sarif: empty.sarif has zero results" {
    result=$(jq '[.runs[].results[]] | length' "$FIXTURES_DIR/empty.sarif")
    [ "$result" -eq 0 ]
}

@test "sarif: findings.sarif has 2 results" {
    result=$(jq '[.runs[].results[]] | length' "$FIXTURES_DIR/findings.sarif")
    [ "$result" -eq 2 ]
}

@test "sarif: findings.sarif results have ruleId" {
    result=$(jq -r '.runs[0].results[0].ruleId' "$FIXTURES_DIR/findings.sarif")
    [ "$result" = "TEST-001" ]
}

@test "sarif: malformed.sarif results is not an array" {
    result=$(jq -r '.runs[0].results | type' "$FIXTURES_DIR/malformed.sarif")
    [ "$result" = "string" ]
}

@test "sarif: injection.sarif contains HTML in tool name" {
    result=$(jq -r '.runs[0].tool.driver.name' "$FIXTURES_DIR/injection.sarif")
    [[ "$result" == *"<script>"* ]]
}

@test "sarif: injection.sarif contains HTML in message" {
    result=$(jq -r '.runs[0].results[0].message.text' "$FIXTURES_DIR/injection.sarif")
    [[ "$result" == *"<img"* ]]
}
