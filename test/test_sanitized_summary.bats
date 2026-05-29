#!/usr/bin/env bats

# Tests for lib/format_sarif_summary.sh (sanitized version)
# Replaces tests for the old tools/format_sarif_summary.sh

setup() {
    export TEST_DIR="$(mktemp -d)"
    export ORIG_DIR="$(pwd)"
    export FORMATTER="$ORIG_DIR/lib/format_sarif_summary.sh"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

@test "sanitized summary: produces markdown table header" {
    mkdir -p "$TEST_DIR/metadata/test-tool"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/test-tool/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" == *"# Wrangle results"* ]]
    [[ "$output" == *"| Tool | Status | Results |"* ]]
}

@test "sanitized summary: reports no findings for empty results" {
    mkdir -p "$TEST_DIR/metadata/test-tool"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/test-tool/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" == *"No findings"* ]]
}

@test "sanitized summary: reports finding count" {
    mkdir -p "$TEST_DIR/metadata/test-tool"
    cp "$ORIG_DIR/test/fixtures/findings.sarif" "$TEST_DIR/metadata/test-tool/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" == *"2 findings"* ]]
}

@test "sanitized summary: handles multiple tools" {
    mkdir -p "$TEST_DIR/metadata/tool-a" "$TEST_DIR/metadata/tool-b"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/tool-a/output.sarif"
    cp "$ORIG_DIR/test/fixtures/findings.sarif" "$TEST_DIR/metadata/tool-b/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" == *"tool-a"* ]]
    [[ "$output" == *"tool-b"* ]]
}

@test "sanitized summary: strips HTML tags from output.txt" {
    mkdir -p "$TEST_DIR/metadata/injected"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/injected/output.sarif"
    printf '<script>alert("xss")</script>Some real content' > "$TEST_DIR/metadata/injected/output.txt"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    # HTML tags should be stripped
    [[ "$output" != *"<script>"* ]]
    # Content should remain
    [[ "$output" == *"Some real content"* ]]
}

@test "sanitized summary: strips HTML tags from output.md" {
    mkdir -p "$TEST_DIR/metadata/injected"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/injected/output.sarif"
    printf '<img src=x onerror=alert(1)>Safe markdown' > "$TEST_DIR/metadata/injected/output.md"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" != *"<img"* ]]
    [[ "$output" != *"onerror"* ]]
    [[ "$output" == *"Safe markdown"* ]]
}

@test "sanitized summary: strips HTML from SARIF tool names" {
    mkdir -p "$TEST_DIR/metadata/injected"
    cp "$ORIG_DIR/test/fixtures/injection.sarif" "$TEST_DIR/metadata/injected/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    # The tool name in the table should not contain script tags
    # (injection.sarif has a tool named with <script> tags)
    [[ "$output" != *"<script>"* ]]
}

@test "sanitized summary: handles malformed SARIF gracefully" {
    mkdir -p "$TEST_DIR/metadata/broken"
    cp "$ORIG_DIR/test/fixtures/malformed.sarif" "$TEST_DIR/metadata/broken/output.sarif"

    run "$FORMATTER" "$TEST_DIR/metadata"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Error (invalid SARIF)"* ]]
}

@test "sanitized summary: requires metadata_dir argument" {
    run "$FORMATTER"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "sanitized summary: fails on nonexistent directory" {
    run "$FORMATTER" "/nonexistent"

    [ "$status" -eq 1 ]
}

@test "sanitized summary: handles empty metadata directory" {
    mkdir -p "$TEST_DIR/metadata"

    run "$FORMATTER" "$TEST_DIR/metadata"

    [ "$status" -eq 0 ]
    [[ "$output" == *"# Wrangle results"* ]]
}

@test "sanitized summary: uses code blocks for txt output (no raw HTML)" {
    mkdir -p "$TEST_DIR/metadata/test-tool"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/test-tool/output.sarif"
    printf 'Some output text' > "$TEST_DIR/metadata/test-tool/output.txt"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    # Should use code blocks, not <pre><code> tags
    [[ "$output" == *'```'* ]]
    [[ "$output" != *"<pre>"* ]]
    [[ "$output" != *"<code>"* ]]
}

# --- Findings rendering (issue #158) ---

@test "sanitized summary: SARIF-only tool falls back to rendering findings table" {
    # Tool produced SARIF but no human-readable output.md/output.txt —
    # the summary must still show WHAT was found (issue #158).
    mkdir -p "$TEST_DIR/metadata/raw-tool"
    cp "$ORIG_DIR/test/fixtures/findings.sarif" "$TEST_DIR/metadata/raw-tool/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    # Details section header is present
    [[ "$output" == *"## raw-tool Details"* ]]
    # Rule ID and location appear (sourced from SARIF via sarif_to_md.sh)
    [[ "$output" == *"TEST-001"* ]]
    [[ "$output" == *"src/main.c:10"* ]]
    [[ "$output" == *"src/utils.c:42"* ]]
    [[ "$output" == *"A test vulnerability was found"* ]]
}

@test "sanitized summary: SARIF-only tool with no findings produces no findings rows" {
    mkdir -p "$TEST_DIR/metadata/clean"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/clean/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    # Status row still shows "No findings"
    [[ "$output" == *"No findings"* ]]
    # No table header rendered (no findings to show)
    [[ "$output" != *"| Severity | Rule | Location | Message |"* ]]
}

@test "sanitized summary: output.md takes precedence over SARIF fallback" {
    # When a tool supplies its own output.md (e.g., zizmor/OSV), use it
    # rather than the generic SARIF fallback.
    mkdir -p "$TEST_DIR/metadata/with-md"
    cp "$ORIG_DIR/test/fixtures/findings.sarif" "$TEST_DIR/metadata/with-md/output.sarif"
    printf '%s' "Tool-specific markdown content" > "$TEST_DIR/metadata/with-md/output.md"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" == *"Tool-specific markdown content"* ]]
    # Generic findings table would include "TEST-001" rows — must not appear.
    [[ "$output" != *"TEST-001"* ]]
}

@test "sanitized summary: SARIF fallback sanitizes injection content" {
    mkdir -p "$TEST_DIR/metadata/injected"
    cp "$ORIG_DIR/test/fixtures/injection.sarif" "$TEST_DIR/metadata/injected/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    # The injection fixture has 1 finding with HTML in the message
    [[ "$output" == *"INJECT-001"* ]]
    # HTML tags from message must be stripped
    [[ "$output" != *"<img"* ]]
    [[ "$output" != *"<script>"* ]]
    [[ "$output" != *"onerror"* ]]
}
