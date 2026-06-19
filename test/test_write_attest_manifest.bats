#!/usr/bin/env bats

# Tests for lib/write_attest_manifest.sh — the producer-side helper that writes
# the wrangle_attestation_metadata.json the wrangle-attest engine discovers.

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../lib" && pwd)/write_attest_manifest.sh"
    TEST_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "write_attest_manifest: writes the pinned schema for an SBOM" {
    run "$SCRIPT" "$TEST_DIR/meta" "https://spdx.dev/Document" "sbom.spdx.json"
    [[ "$status" -eq 0 ]]
    run jq -r '."predicate-type"' "$TEST_DIR/meta/wrangle_attestation_metadata.json"
    [[ "$output" == "https://spdx.dev/Document" ]]
    run jq -r '."result-file"' "$TEST_DIR/meta/wrangle_attestation_metadata.json"
    [[ "$output" == "sbom.spdx.json" ]]
    # Passthrough manifests carry no tool/result fields.
    run jq -e 'has("tool") or has("result")' "$TEST_DIR/meta/wrangle_attestation_metadata.json"
    [[ "$status" -ne 0 ]]
}

@test "write_attest_manifest: creates the metadata dir if absent" {
    run "$SCRIPT" "$TEST_DIR/nested/dir" "https://spdx.dev/Document" "sbom.spdx.json"
    [[ "$status" -eq 0 ]]
    [[ -f "$TEST_DIR/nested/dir/wrangle_attestation_metadata.json" ]]
}

@test "write_attest_manifest: jq-escapes a value with quotes (no broken JSON)" {
    # A pathological result-file name must not break the manifest the engine
    # parses strictly; jq -n escapes it.
    run "$SCRIPT" "$TEST_DIR/meta" 'https://spdx.dev/Document' 'we"ird.json'
    [[ "$status" -eq 0 ]]
    run jq -r '."result-file"' "$TEST_DIR/meta/wrangle_attestation_metadata.json"
    [[ "$output" == 'we"ird.json' ]]
}

@test "write_attest_manifest: usage error on wrong arg count" {
    run "$SCRIPT" "$TEST_DIR/meta" "https://spdx.dev/Document"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"Usage:"* ]]
}
