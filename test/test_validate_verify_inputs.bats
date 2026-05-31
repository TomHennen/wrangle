#!/usr/bin/env bats

# Tests for actions/verify/validate_verify_inputs.sh

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/actions/verify/validate_verify_inputs.sh"
}

# Canonical good argument vector: artifact subject policy collector fail context attestation
good() {
    "$SCRIPT" "app-1.2.3.tgz" "sha256:abc123" "policies/release.json" \
        "jsonl:./atts" "true" "" ""
}

@test "validate_verify_inputs: exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "validate_verify_inputs: requires exactly seven arguments" {
    run "$SCRIPT"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
    run "$SCRIPT" a b c
    [[ "$status" -ne 0 ]]
}

@test "validate_verify_inputs: accepts a typical valid input set" {
    run good
    [[ "$status" -eq 0 ]]
}

@test "validate_verify_inputs: accepts optional context and attestation" {
    run "$SCRIPT" "app.tgz" "sha256:abc" "policies/p.json" "oci:img,jsonl:a" \
        "false" "buildPoint:git+https://github.com/o/r" "att.intoto.json"
    [[ "$status" -eq 0 ]]
}

@test "validate_verify_inputs: accepts empty context and attestation" {
    run "$SCRIPT" "app.tgz" "sha256:abc" "p.json" "jsonl:a" "true" "" ""
    [[ "$status" -eq 0 ]]
}

# --- artifact-name ---

@test "validate_verify_inputs: rejects artifact-name with leading dot" {
    run "$SCRIPT" ".hidden" "sha256:abc" "p.json" "jsonl:a" "true" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"artifact-name"* ]]
}

@test "validate_verify_inputs: rejects artifact-name with slash" {
    run "$SCRIPT" "a/b.tgz" "sha256:abc" "p.json" "jsonl:a" "true" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"artifact-name"* ]]
}

@test "validate_verify_inputs: rejects artifact-name with shell metacharacters" {
    run "$SCRIPT" 'a;rm -rf /' "sha256:abc" "p.json" "jsonl:a" "true" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"artifact-name"* ]]
}

# --- subject / policy / collector ---

@test "validate_verify_inputs: rejects subject with command substitution" {
    run "$SCRIPT" "app.tgz" 'sha256:$(id)' "p.json" "jsonl:a" "true" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"subject"* ]]
}

@test "validate_verify_inputs: rejects subject with semicolon" {
    run "$SCRIPT" "app.tgz" "sha256:abc;ls" "p.json" "jsonl:a" "true" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"subject"* ]]
}

@test "validate_verify_inputs: rejects policy with backtick" {
    run "$SCRIPT" "app.tgz" "sha256:abc" 'p`id`.json' "jsonl:a" "true" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"policy"* ]]
}

@test "validate_verify_inputs: rejects collector with space" {
    run "$SCRIPT" "app.tgz" "sha256:abc" "p.json" "jsonl:a b" "true" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"collector"* ]]
}

@test "validate_verify_inputs: rejects empty subject" {
    run "$SCRIPT" "app.tgz" "" "p.json" "jsonl:a" "true" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"subject"* ]]
}

# --- fail ---

@test "validate_verify_inputs: rejects non-boolean fail" {
    run "$SCRIPT" "app.tgz" "sha256:abc" "p.json" "jsonl:a" "yes" "" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"fail"* ]]
}

# --- context / attestation metacharacters ---

@test "validate_verify_inputs: rejects context with shell metacharacters" {
    run "$SCRIPT" "app.tgz" "sha256:abc" "p.json" "jsonl:a" "true" 'k:$(id)' ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"context"* ]]
}

@test "validate_verify_inputs: rejects attestation with newline injection" {
    run "$SCRIPT" "app.tgz" "sha256:abc" "p.json" "jsonl:a" "true" "" $'a\nb'
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"attestation"* ]]
}

# --- sourced form ---

@test "validate_verify_inputs: function is sourceable and callable" {
    # shellcheck source=../../lib/validate_verify_inputs.sh
    source "$SCRIPT"
    run wrangle_validate_verify_inputs "app.tgz" "sha256:abc" "p.json" "jsonl:a" "true" "" ""
    [[ "$status" -eq 0 ]]
    run wrangle_validate_verify_inputs "app.tgz" "bad;rm" "p.json" "jsonl:a" "true" "" ""
    [[ "$status" -ne 0 ]]
}
