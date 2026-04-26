#!/usr/bin/env bats

# Tests for lib/validate_path.sh

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$REPO_ROOT/lib/validate_path.sh"
}

@test "validate_path: exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "validate_path: requires exactly one argument" {
    run "$SCRIPT"
    [[ "$status" -ne 0 ]]
    run "$SCRIPT" a b
    [[ "$status" -ne 0 ]]
}

@test "validate_path: accepts plain relative path" {
    run "$SCRIPT" "src"
    [[ "$status" -eq 0 ]]
}

@test "validate_path: accepts nested relative path" {
    run "$SCRIPT" "pkg/foo/bar"
    [[ "$status" -eq 0 ]]
}

@test "validate_path: accepts dot" {
    run "$SCRIPT" "."
    [[ "$status" -eq 0 ]]
}

@test "validate_path: rejects absolute path" {
    run "$SCRIPT" "/etc"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"path must be relative"* ]]
}

@test "validate_path: rejects parent traversal" {
    run "$SCRIPT" "../etc"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"traversal"* ]]
}

@test "validate_path: rejects embedded traversal" {
    run "$SCRIPT" "src/../etc"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"traversal"* ]]
}

@test "validate_path: rejects shell metacharacters" {
    run "$SCRIPT" 'src;rm -rf /'
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"invalid characters"* ]]
}

@test "validate_path: rejects spaces" {
    run "$SCRIPT" "my dir"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"invalid characters"* ]]
}

@test "validate_path: rejects glob characters" {
    run "$SCRIPT" "src/*.py"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"invalid characters"* ]]
}
