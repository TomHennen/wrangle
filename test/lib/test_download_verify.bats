#!/usr/bin/env bats

# Tests for lib/download_verify.sh
# TDD: these tests define the contract before implementation.

setup() {
    export TEST_DIR="$(mktemp -d)"
    export ORIG_DIR="$(pwd)"

    # Source the library
    # shellcheck source=../../lib/download_verify.sh
    source "$ORIG_DIR/lib/download_verify.sh"

    # Create a test file to serve as a "downloaded" artifact
    echo "test binary content" > "$TEST_DIR/test_artifact"
    EXPECTED_SHA256="$(sha256sum "$TEST_DIR/test_artifact" | cut -d' ' -f1)"

    # Create a mock curl that parses -o flag like real curl
    # Usage: curl -fsSL -o <output_file> <url>
    cat > "$TEST_DIR/curl" << 'MOCK_CURL'
#!/bin/bash
# Parse args to find -o <output> and behave based on TEST_DIR control files
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2 ;;
        -*) shift ;;
        *) shift ;;
    esac
done

# Check if we should fail
if [[ -f "${TEST_DIR}/curl_fail" ]]; then
    count=0
    [[ -f "${TEST_DIR}/call_count" ]] && count=$(cat "${TEST_DIR}/call_count")
    count=$((count + 1))
    echo "$count" > "${TEST_DIR}/call_count"
    fail_until=$(cat "${TEST_DIR}/curl_fail")
    if [[ "$count" -lt "$fail_until" ]]; then
        exit 1
    fi
fi

# Check if we should always fail
if [[ -f "${TEST_DIR}/curl_always_fail" ]]; then
    exit 1
fi

cp "${TEST_DIR}/test_artifact" "$output_file"
MOCK_CURL
    chmod +x "$TEST_DIR/curl"

    # Create a no-op sleep
    cat > "$TEST_DIR/sleep" << 'MOCK_SLEEP'
#!/bin/bash
exit 0
MOCK_SLEEP
    chmod +x "$TEST_DIR/sleep"

    # Prepend mock dir to PATH so our mocks are found first
    export PATH="$TEST_DIR:$PATH"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

# --- wrangle_download_verify tests ---

@test "download_verify: succeeds with correct checksum" {
    local output_path="$TEST_DIR/output_binary"
    run wrangle_download_verify "https://example.com/tool" "$EXPECTED_SHA256" "$output_path"

    [ "$status" -eq 0 ]
    [ -f "$output_path" ]
}

@test "download_verify: fails with wrong checksum" {
    local output_path="$TEST_DIR/output_binary"
    run wrangle_download_verify "https://example.com/tool" "0000000000000000000000000000000000000000000000000000000000000000" "$output_path"

    [ "$status" -eq 1 ]
    [ ! -f "$output_path" ]
}

@test "download_verify: cleans up temp file on checksum failure" {
    local output_path="$TEST_DIR/output_binary"
    wrangle_download_verify "https://example.com/tool" "bad_checksum" "$output_path" || true

    # No temp files should remain
    local leftover
    leftover=$(find "$TEST_DIR" -name 'wrangle-dl-*' 2>/dev/null | wc -l)
    [ "$leftover" -eq 0 ]
}

@test "download_verify: retries on download failure" {
    # Fail the first 2 attempts, succeed on attempt 3
    echo "0" > "$TEST_DIR/call_count"
    echo "3" > "$TEST_DIR/curl_fail"

    local output_path="$TEST_DIR/output_binary"
    run wrangle_download_verify "https://example.com/tool" "$EXPECTED_SHA256" "$output_path"

    [ "$status" -eq 0 ]
    [ -f "$output_path" ]
    [ "$(cat "$TEST_DIR/call_count")" -eq 3 ]
}

@test "download_verify: fails after max retries exhausted" {
    touch "$TEST_DIR/curl_always_fail"

    local output_path="$TEST_DIR/output_binary"
    run wrangle_download_verify "https://example.com/tool" "$EXPECTED_SHA256" "$output_path"

    [ "$status" -eq 1 ]
    [ ! -f "$output_path" ]
}

@test "download_verify: requires 3 arguments" {
    run wrangle_download_verify "https://example.com/tool" "somechecksum"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "download_verify: uses atomic mv to place binary" {
    local output_path="$TEST_DIR/output_binary"
    wrangle_download_verify "https://example.com/tool" "$EXPECTED_SHA256" "$output_path"

    # File should exist at output path and be readable
    [ -f "$output_path" ]
    [ -r "$output_path" ]
}

# --- wrangle_verify_provenance tests ---

@test "verify_provenance: fails when slsa-verifier not available" {
    # Use a restricted PATH that definitely won't have slsa-verifier
    PATH="/usr/bin:/bin" run wrangle_verify_provenance "$TEST_DIR/test_artifact" "test/repo" "v1.0.0"

    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot verify provenance"* ]]
}

@test "verify_provenance: requires 3 arguments" {
    run wrangle_verify_provenance "$TEST_DIR/test_artifact" "test/repo"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

# --- wrangle_verify_signature tests ---

@test "verify_signature: fails when cosign not available" {
    PATH="/usr/bin:/bin" run wrangle_verify_signature "$TEST_DIR/test_artifact" "expected-identity" "expected-issuer"

    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot verify signature"* ]]
}

@test "verify_signature: requires 3 arguments" {
    run wrangle_verify_signature "$TEST_DIR/test_artifact" "expected-identity"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}
