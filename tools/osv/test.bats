#!/usr/bin/env bats

# Tests for tools/osv/ (install.sh and adapter.sh)
# Uses mock osv-scanner binary for fast, deterministic testing.

setup() {
    export TEST_DIR="$(mktemp -d)"
    export ORIG_DIR="$(pwd)"
    export MOCK_BIN="$TEST_DIR/mock_bin"
    mkdir -p "$MOCK_BIN" "$TEST_DIR/src" "$TEST_DIR/output"

    # Create a mock osv-scanner that produces fixture SARIF
    cat > "$MOCK_BIN/osv-scanner" << 'MOCK'
#!/bin/bash
# Mock osv-scanner: behavior controlled by OSV_MOCK_MODE env var
# Supports: clean, findings, no-sources, error, bad-json

# Handle --version flag
for arg in "$@"; do
    if [[ "$arg" == "--version" ]]; then
        echo "osv-scanner version 2.3.5-mock"
        exit 0
    fi
done

# Parse args to find --output and --format
output_file=""
format=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output_file="$2"; shift 2 ;;
        --format) format="$2"; shift 2 ;;
        *) shift ;;
    esac
done

case "${OSV_MOCK_MODE:-clean}" in
    clean)
        if [[ "$format" == "sarif" ]]; then
            cat > "$output_file" << 'SARIF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [{"tool": {"driver": {"name": "osv-scanner", "version": "2.3.5"}}, "results": []}]
}
SARIF
        elif [[ "$format" == "markdown" ]]; then
            echo "No vulnerabilities found." > "$output_file"
        fi
        exit 0
        ;;
    findings)
        if [[ "$format" == "sarif" ]]; then
            cat > "$output_file" << 'SARIF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [{"tool": {"driver": {"name": "osv-scanner", "version": "2.3.5", "rules": [{"id": "GHSA-1234-5678-abcd", "shortDescription": {"text": "Test vulnerability"}}]}}, "results": [{"ruleId": "GHSA-1234-5678-abcd", "level": "error", "message": {"text": "Package foo@1.0.0 is affected by GHSA-1234-5678-abcd"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "package-lock.json"}, "region": {"startLine": 1}}}]}]}]
}
SARIF
        elif [[ "$format" == "markdown" ]]; then
            echo "| Package | Version | Vulnerability |" > "$output_file"
        fi
        exit 1
        ;;
    no-sources)
        exit 128
        ;;
    error)
        exit 2
        ;;
    bad-json)
        if [[ "$format" == "sarif" ]]; then
            echo "not valid json{{{" > "$output_file"
        fi
        exit 0
        ;;
esac
MOCK
    chmod +x "$MOCK_BIN/osv-scanner"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

# --- adapter.sh tests ---

@test "osv adapter: produces SARIF with no findings (exit 0)" {
    export OSV_MOCK_MODE="clean"
    run "$ORIG_DIR/tools/osv/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/output.sarif" ]
    # Validate it's proper SARIF
    jq empty "$TEST_DIR/output/output.sarif"
    result=$(jq '[.runs[].results[]] | length' "$TEST_DIR/output/output.sarif")
    [ "$result" -eq 0 ]
}

@test "osv adapter: produces SARIF with findings (exit 1)" {
    export OSV_MOCK_MODE="findings"
    run "$ORIG_DIR/tools/osv/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 1 ]
    [ -f "$TEST_DIR/output/output.sarif" ]
    result=$(jq '[.runs[].results[]] | length' "$TEST_DIR/output/output.sarif")
    [ "$result" -gt 0 ]
}

@test "osv adapter: handles no package sources (exit 0, empty SARIF)" {
    export OSV_MOCK_MODE="no-sources"
    run "$ORIG_DIR/tools/osv/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/output.sarif" ]
    jq empty "$TEST_DIR/output/output.sarif"
    result=$(jq '[.runs[].results[]] | length' "$TEST_DIR/output/output.sarif")
    [ "$result" -eq 0 ]
}

@test "osv adapter: tool error produces exit 2" {
    export OSV_MOCK_MODE="error"
    run "$ORIG_DIR/tools/osv/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 2 ]
}

@test "osv adapter: invalid JSON SARIF produces exit 2" {
    export OSV_MOCK_MODE="bad-json"
    run "$ORIG_DIR/tools/osv/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 2 ]
}

@test "osv adapter: requires 2 arguments" {
    run "$ORIG_DIR/tools/osv/adapter.sh" "$TEST_DIR/src"

    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]
}

@test "osv adapter: fails if src_dir does not exist" {
    run "$ORIG_DIR/tools/osv/adapter.sh" "/nonexistent" "$TEST_DIR/output"

    [ "$status" -eq 2 ]
}

@test "osv adapter: fails if output_dir does not exist" {
    run "$ORIG_DIR/tools/osv/adapter.sh" "$TEST_DIR/src" "/nonexistent"

    [ "$status" -eq 2 ]
}

@test "osv adapter: generates markdown output on clean scan" {
    export OSV_MOCK_MODE="clean"
    run "$ORIG_DIR/tools/osv/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/output.md" ]
}

# --- install.sh tests ---

@test "osv install: sources download_verify library" {
    # Verify the install script can at least be parsed (syntax check)
    run bash -n "$ORIG_DIR/tools/osv/install.sh"

    [ "$status" -eq 0 ]
}

@test "osv install: skips if correct version already installed" {
    # Mock osv-scanner already exists in MOCK_BIN and reports 2.3.5
    export WRANGLE_BIN_DIR="$MOCK_BIN"

    run "$ORIG_DIR/tools/osv/install.sh" "2.3.5"

    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

@test "osv install: fails if binary download fails" {
    export WRANGLE_BIN_DIR="$TEST_DIR/install_bin"
    mkdir -p "$WRANGLE_BIN_DIR"

    # Create a mock curl that always fails
    cat > "$TEST_DIR/mock_curl" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TEST_DIR/mock_curl"
    PATH="$TEST_DIR:$PATH"
    ln -sf "$TEST_DIR/mock_curl" "$TEST_DIR/curl"

    run "$ORIG_DIR/tools/osv/install.sh" "2.3.5"

    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    # Binary should not exist
    [ ! -f "$WRANGLE_BIN_DIR/osv-scanner" ]
}

@test "osv install: fails if provenance download fails" {
    export WRANGLE_BIN_DIR="$TEST_DIR/install_bin"
    mkdir -p "$WRANGLE_BIN_DIR"

    # Create a mock curl that succeeds for binary but fails for provenance
    echo "0" > "$TEST_DIR/curl_call_count"
    cat > "$TEST_DIR/curl" << 'MOCK'
#!/bin/bash
count=$(cat "$TEST_DIR/curl_call_count")
count=$((count + 1))
echo "$count" > "$TEST_DIR/curl_call_count"
# First call (binary download) succeeds
if [ "$count" -eq 1 ]; then
    # Parse -o flag to find output file
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) echo "fake binary" > "$2"; exit 0 ;;
            *) shift ;;
        esac
    done
fi
# Second call (provenance download) fails
exit 1
MOCK
    chmod +x "$TEST_DIR/curl"
    PATH="$TEST_DIR:$PATH"

    run "$ORIG_DIR/tools/osv/install.sh" "2.3.5"

    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"provenance"* ]]
    # Binary and provenance files should be cleaned up
    leftover=$(find "$WRANGLE_BIN_DIR" -name 'wrangle-dl-*' -o -name '*.intoto.jsonl' 2>/dev/null | wc -l)
    [ "$leftover" -eq 0 ]
}

@test "osv install: fails if provenance verification fails" {
    export WRANGLE_BIN_DIR="$TEST_DIR/install_bin"
    mkdir -p "$WRANGLE_BIN_DIR"

    # Create a mock curl that always succeeds (writes dummy files)
    cat > "$TEST_DIR/curl" << 'MOCK'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in
        -o) echo "fake content" > "$2"; exit 0 ;;
        *) shift ;;
    esac
done
exit 0
MOCK
    chmod +x "$TEST_DIR/curl"

    # Create a mock slsa-verifier that always fails
    cat > "$TEST_DIR/slsa-verifier" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TEST_DIR/slsa-verifier"
    PATH="$TEST_DIR:$PATH"

    run "$ORIG_DIR/tools/osv/install.sh" "2.3.5"

    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"supply chain attack"* ]]
    # Binary and provenance files should be cleaned up
    [ ! -f "$WRANGLE_BIN_DIR/osv-scanner" ]
}
