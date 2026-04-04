#!/usr/bin/env bats

# Tests for tools/zizmor/ (install.sh and adapter.sh)
# Uses mock zizmor binary for fast, deterministic testing.

setup() {
    export TEST_DIR="$(mktemp -d)"
    export ORIG_DIR="$(pwd)"
    export MOCK_BIN="$TEST_DIR/mock_bin"
    mkdir -p "$MOCK_BIN" "$TEST_DIR/src/.github/workflows" "$TEST_DIR/output"

    # Create a dummy workflow file for scanning
    cat > "$TEST_DIR/src/.github/workflows/test.yml" << 'YML'
name: Test
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YML

    # Create a mock zizmor that produces fixture output
    cat > "$MOCK_BIN/zizmor" << 'MOCK'
#!/bin/bash
# Mock zizmor: behavior controlled by ZIZMOR_MOCK_MODE env var

# Handle --version flag
for arg in "$@"; do
    if [[ "$arg" == "--version" ]]; then
        echo "zizmor 1.23.1"
        exit 0
    fi
done

# Parse --format flag
format=""
for arg in "$@"; do
    if [[ "$prev" == "--format" ]]; then
        format="$arg"
    fi
    prev="$arg"
done

case "${ZIZMOR_MOCK_MODE:-clean}" in
    clean)
        if [[ "$format" == "sarif" ]]; then
            cat << 'SARIF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [{"tool": {"driver": {"name": "zizmor", "version": "1.23.1"}}, "results": []}]
}
SARIF
        elif [[ "$format" == "plain" ]]; then
            echo "No findings."
        fi
        exit 0
        ;;
    findings)
        if [[ "$format" == "sarif" ]]; then
            cat << 'SARIF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [{"tool": {"driver": {"name": "zizmor", "version": "1.23.1", "rules": [{"id": "unpinned-uses", "shortDescription": {"text": "Unpinned action reference"}}]}}, "results": [{"ruleId": "unpinned-uses", "kind": "fail", "level": "warning", "message": {"text": "Unpinned action: actions/checkout@v4"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": ".github/workflows/test.yml"}, "region": {"startLine": 7}}}]}]}]
}
SARIF
        elif [[ "$format" == "plain" ]]; then
            echo "warning: unpinned-uses (.github/workflows/test.yml:7)"
        fi
        exit 1
        ;;
    bad-json)
        if [[ "$format" == "sarif" ]]; then
            echo "not valid json{{{"
        fi
        exit 0
        ;;
esac
MOCK
    chmod +x "$MOCK_BIN/zizmor"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

# --- adapter.sh tests ---

@test "zizmor adapter: produces SARIF with no findings (exit 0)" {
    export ZIZMOR_MOCK_MODE="clean"
    run "$ORIG_DIR/tools/zizmor/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/output.sarif" ]
    jq empty "$TEST_DIR/output/output.sarif"
    result=$(jq '[.runs[].results[]] | length' "$TEST_DIR/output/output.sarif")
    [ "$result" -eq 0 ]
}

@test "zizmor adapter: produces SARIF with findings (exit 1)" {
    export ZIZMOR_MOCK_MODE="findings"
    run "$ORIG_DIR/tools/zizmor/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 1 ]
    [ -f "$TEST_DIR/output/output.sarif" ]
    result=$(jq '[.runs[].results[]] | length' "$TEST_DIR/output/output.sarif")
    [ "$result" -gt 0 ]
}

@test "zizmor adapter: detects fail kind in results" {
    export ZIZMOR_MOCK_MODE="findings"
    run "$ORIG_DIR/tools/zizmor/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 1 ]
    has_fail=$(jq 'any(.runs[].results[].kind; contains("fail"))' "$TEST_DIR/output/output.sarif")
    [ "$has_fail" = "true" ]
}

@test "zizmor adapter: invalid JSON SARIF produces exit 2" {
    export ZIZMOR_MOCK_MODE="bad-json"
    run "$ORIG_DIR/tools/zizmor/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 2 ]
}

@test "zizmor adapter: requires 2 arguments" {
    run "$ORIG_DIR/tools/zizmor/adapter.sh" "$TEST_DIR/src"

    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]
}

@test "zizmor adapter: fails if src_dir does not exist" {
    run "$ORIG_DIR/tools/zizmor/adapter.sh" "/nonexistent" "$TEST_DIR/output"

    [ "$status" -eq 2 ]
}

@test "zizmor adapter: fails if output_dir does not exist" {
    run "$ORIG_DIR/tools/zizmor/adapter.sh" "$TEST_DIR/src" "/nonexistent"

    [ "$status" -eq 2 ]
}

@test "zizmor adapter: handles missing .github/workflows (exit 0, empty SARIF)" {
    local no_workflows="$TEST_DIR/empty_src"
    mkdir -p "$no_workflows"

    run "$ORIG_DIR/tools/zizmor/adapter.sh" "$no_workflows" "$TEST_DIR/output"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/output.sarif" ]
    jq empty "$TEST_DIR/output/output.sarif"
    result=$(jq '[.runs[].results[]] | length' "$TEST_DIR/output/output.sarif")
    [ "$result" -eq 0 ]
}

@test "zizmor adapter: handles empty workflows directory (exit 0, empty SARIF)" {
    local empty_workflows="$TEST_DIR/empty_wf_src"
    mkdir -p "$empty_workflows/.github/workflows"

    run "$ORIG_DIR/tools/zizmor/adapter.sh" "$empty_workflows" "$TEST_DIR/output"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/output.sarif" ]
    result=$(jq '[.runs[].results[]] | length' "$TEST_DIR/output/output.sarif")
    [ "$result" -eq 0 ]
}

@test "zizmor adapter: generates text output on clean scan" {
    export ZIZMOR_MOCK_MODE="clean"
    run "$ORIG_DIR/tools/zizmor/adapter.sh" "$TEST_DIR/src" "$TEST_DIR/output"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/output.txt" ]
}

# --- install.sh tests ---

@test "zizmor install: sources download_verify library" {
    run bash -n "$ORIG_DIR/tools/zizmor/install.sh"

    [ "$status" -eq 0 ]
}

@test "zizmor install: skips if correct version already installed" {
    export WRANGLE_BIN_DIR="$MOCK_BIN"

    run "$ORIG_DIR/tools/zizmor/install.sh" "1.23.1"

    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}
