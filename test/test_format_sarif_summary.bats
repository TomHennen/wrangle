#!/usr/bin/env bats

# Tests for tools/format_sarif_summary.sh
# These test the existing script to establish a baseline before migration.

setup() {
    # Create a temporary metadata directory structure
    export TEST_DIR="$(mktemp -d)"
    export ORIG_DIR="$(pwd)"
    cd "$TEST_DIR"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

@test "format_sarif_summary: produces markdown table header" {
    mkdir -p metadata/test-tool
    cp "$ORIG_DIR/test/fixtures/empty.sarif" metadata/test-tool/output.sarif

    output=$("$ORIG_DIR/tools/format_sarif_summary.sh")

    [[ "$output" == *"# Wrangle results"* ]]
    [[ "$output" == *"| Tool | Status | Results |"* ]]
}

@test "format_sarif_summary: reports no findings for empty results" {
    mkdir -p metadata/test-tool
    cp "$ORIG_DIR/test/fixtures/empty.sarif" metadata/test-tool/output.sarif

    output=$("$ORIG_DIR/tools/format_sarif_summary.sh")

    [[ "$output" == *"No findings"* ]]
}

@test "format_sarif_summary: reports finding count for results with findings" {
    mkdir -p metadata/test-tool
    cp "$ORIG_DIR/test/fixtures/findings.sarif" metadata/test-tool/output.sarif

    output=$("$ORIG_DIR/tools/format_sarif_summary.sh")

    [[ "$output" == *"2 findings"* ]]
}

@test "format_sarif_summary: includes tool details from output.txt" {
    mkdir -p metadata/test-tool
    cp "$ORIG_DIR/test/fixtures/empty.sarif" metadata/test-tool/output.sarif
    echo "Some detailed output" > metadata/test-tool/output.txt

    output=$("$ORIG_DIR/tools/format_sarif_summary.sh")

    [[ "$output" == *"test-tool Details"* ]]
    [[ "$output" == *"Some detailed output"* ]]
}

@test "format_sarif_summary: includes tool details from output.md" {
    mkdir -p metadata/test-tool
    cp "$ORIG_DIR/test/fixtures/empty.sarif" metadata/test-tool/output.sarif
    echo "## Markdown details" > metadata/test-tool/output.md

    output=$("$ORIG_DIR/tools/format_sarif_summary.sh")

    [[ "$output" == *"test-tool Details"* ]]
    [[ "$output" == *"Markdown details"* ]]
}

@test "format_sarif_summary: handles multiple tools" {
    mkdir -p metadata/tool-a metadata/tool-b
    cp "$ORIG_DIR/test/fixtures/empty.sarif" metadata/tool-a/output.sarif
    cp "$ORIG_DIR/test/fixtures/findings.sarif" metadata/tool-b/output.sarif

    output=$("$ORIG_DIR/tools/format_sarif_summary.sh")

    [[ "$output" == *"tool-a"* ]]
    [[ "$output" == *"tool-b"* ]]
    [[ "$output" == *"No findings"* ]]
    [[ "$output" == *"2 findings"* ]]
}

@test "format_sarif_summary: handles missing sarif gracefully" {
    mkdir -p metadata/no-sarif
    echo "just text" > metadata/no-sarif/output.txt

    # Should not crash, just skip the tool in the summary table
    run "$ORIG_DIR/tools/format_sarif_summary.sh"

    [ "$status" -eq 0 ]
}
