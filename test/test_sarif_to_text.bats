#!/usr/bin/env bats

# Tests for lib/sarif_to_text.sh

setup() {
    export ORIG_DIR="$(pwd)"
    export SCRIPT="$ORIG_DIR/lib/sarif_to_text.sh"
}

@test "sarif_to_text: requires sarif_file argument" {
    run "$SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "sarif_to_text: fails on nonexistent file" {
    run "$SCRIPT" "/nonexistent/file.sarif"

    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "sarif_to_text: fails on malformed SARIF" {
    run "$SCRIPT" "$ORIG_DIR/test/fixtures/malformed.sarif"

    [ "$status" -eq 2 ]
}

@test "sarif_to_text: clean SARIF produces no-findings message" {
    run "$SCRIPT" "$ORIG_DIR/test/fixtures/empty.sarif"

    [ "$status" -eq 0 ]
    [[ "$output" == *"No findings"* ]]
}

@test "sarif_to_text: findings include ruleId and location" {
    run "$SCRIPT" "$ORIG_DIR/test/fixtures/findings.sarif"

    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST-001"* ]]
    [[ "$output" == *"src/main.c:10"* ]]
    [[ "$output" == *"src/utils.c:42"* ]]
}

@test "sarif_to_text: error level maps to HIGH" {
    run "$SCRIPT" "$ORIG_DIR/test/fixtures/findings.sarif"

    [ "$status" -eq 0 ]
    [[ "$output" == *"[HIGH]"* ]]
}

@test "sarif_to_text: warning level maps to MED" {
    run "$SCRIPT" "$ORIG_DIR/test/fixtures/findings.sarif"

    [ "$status" -eq 0 ]
    [[ "$output" == *"[MED]"* ]]
}

@test "sarif_to_text: includes message text" {
    run "$SCRIPT" "$ORIG_DIR/test/fixtures/findings.sarif"

    [ "$status" -eq 0 ]
    [[ "$output" == *"A test vulnerability was found"* ]]
    [[ "$output" == *"Another test finding"* ]]
}

@test "sarif_to_text: handles injection SARIF safely" {
    run "$SCRIPT" "$ORIG_DIR/test/fixtures/injection.sarif"

    [ "$status" -eq 0 ]
    [[ "$output" == *"INJECT-001"* ]]
}
