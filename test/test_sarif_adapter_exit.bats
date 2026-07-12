#!/usr/bin/env bats

# Tests for lib/sarif_adapter_exit.sh — the shared adapter exit contract
# (SPEC.md §Adapter Script Interface: 0 = no findings, 1 = findings, 2 = error).

setup() {
    ORIG_DIR="$(pwd)"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sarif-exit-XXXXXX")"
    LIB="$ORIG_DIR/lib/sarif_adapter_exit.sh"
    SARIF="$TMP_DIR/output.sarif"
    export ORIG_DIR TMP_DIR LIB SARIF
}

teardown() {
    rm -rf "$TMP_DIR"
}

# Drives the helper the way an adapter does: sourced, then called as the last
# statement — so a status the helper only raises in a subshell fails here.
run_helper() {
    run bash -c 'source "$1"; wrangle_sarif_adapter_exit "${@:2}"' _ "$LIB" "$@"
}

@test "no results: exit 0" {
    printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"t"}},"results":[]}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 0 ]
}

@test "results present: exit 1" {
    printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"t"}},"results":[{"ruleId":"X"}]}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 1 ]
}

@test "results across multiple runs: exit 1" {
    printf '{"runs":[{"results":[]},{"results":[{"ruleId":"X"}]}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 1 ]
}

@test "malformed JSON: exit 2, never a clean scan" {
    printf '{ not valid json\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
    [[ "$output" == *"wrangle/t: produced invalid JSON"* ]]
}

@test "truncated SARIF: exit 2" {
    printf '{"version":"2.1.0","runs":[{"results":[\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}

@test "empty JSON document: exit 2" {
    printf '{}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
    [[ "$output" == *"missing runs array"* ]]
}

@test "JSON null: exit 2" {
    printf 'null\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}

@test "runs is not an array: exit 2" {
    printf '{"runs":{"results":[]}}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}

@test "runs holds non-objects: exit 2" {
    printf '{"runs":[1,2]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}

@test "results is a string: exit 2" {
    printf '{"runs":[{"results":"x"}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}

@test "results is null: exit 2" {
    printf '{"runs":[{"results":null}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}

@test "results is an object: exit 2" {
    printf '{"runs":[{"results":{"a":{},"b":{}}}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}

@test "concatenated JSON documents: exit 2" {
    printf '{}\n{"runs":[{"results":[{"ruleId":"X"}]}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}

@test "empty file: exit 2" {
    : > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}

@test "clean_exit outside 0/1: exit 2" {
    printf '{"runs":[{"results":[]}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF" 128
    [ "$status" -eq 2 ]
}

@test "missing SARIF file: exit 2" {
    run_helper 'wrangle/t' "$TMP_DIR/does-not-exist.sarif"
    [ "$status" -eq 2 ]
}

@test "run without a results key: exit 0" {
    printf '{"runs":[{"tool":{"driver":{"name":"t"}}}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 0 ]
}

@test "clean_exit overrides the no-findings status" {
    printf '{"runs":[{"results":[]}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF" 1
    [ "$status" -eq 1 ]
}

@test "clean_exit does not override a malformed SARIF" {
    printf 'not json\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF" 0
    [ "$status" -eq 2 ]
}

@test "concatenated JSON documents with a clean tail: exit 2" {
    printf '{}\n{"runs":[{"results":[]}]}\n' > "$SARIF"
    run_helper 'wrangle/t' "$SARIF"
    [ "$status" -eq 2 ]
}
