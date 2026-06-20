#!/usr/bin/env bats

# Tests for lib/format_sarif_summary.sh (sanitized version)
# Replaces tests for the old tools/format_sarif_summary.sh

setup() {
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR
    ORIG_DIR="$(pwd)"
    export ORIG_DIR
    export FORMATTER="$ORIG_DIR/lib/format_sarif_summary.sh"
}

teardown() {
    cd "$ORIG_DIR" || exit 1
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

@test "sanitized summary: passthrough tool (output.md, no SARIF) gets a score row" {
    mkdir -p "$TEST_DIR/metadata/scorecard"
    printf '%s' "Aggregate score: 7.4 / 10" > "$TEST_DIR/metadata/scorecard/output.md"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" == *"| scorecard | Score (see details) |"* ]]
    [[ "$output" == *"Aggregate score: 7.4 / 10"* ]]
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

# --- Tool-error marker ---
#
# Action-pattern tools (e.g., zizmor) signal tool error via an `error`
# marker file in the metadata dir. The summary table — the primary
# adopter output per docs/SPEC.md Composite Action Interface — must
# reflect that marker, not the fallback empty SARIF the wrapper
# synthesises.

@test "sanitized summary: error marker renders as Tool error status" {
    mkdir -p "$TEST_DIR/metadata/zizmor"
    printf 'zizmor crashed: pull failed\n' > "$TEST_DIR/metadata/zizmor/error"
    # Empty fallback SARIF as the wrapper writes it.
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/zizmor/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" == *"Tool error"* ]]
    # We did NOT silently report "No findings" off the fallback SARIF.
    [[ "$output" != *"No findings"* ]]
}

@test "sanitized summary: error marker details surface marker contents" {
    mkdir -p "$TEST_DIR/metadata/zizmor"
    printf 'zizmor exited non-zero: image pull failed\n' > "$TEST_DIR/metadata/zizmor/error"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/zizmor/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" == *"image pull failed"* ]]
    [[ "$output" == *"fail-closed"* ]]
}

@test "sanitized summary: error marker contents are HTML-sanitised" {
    mkdir -p "$TEST_DIR/metadata/zizmor"
    printf '<script>alert(1)</script>real error text\n' > "$TEST_DIR/metadata/zizmor/error"
    cp "$ORIG_DIR/test/fixtures/empty.sarif" "$TEST_DIR/metadata/zizmor/output.sarif"

    output=$("$FORMATTER" "$TEST_DIR/metadata")

    [[ "$output" != *"<script>"* ]]
    [[ "$output" == *"real error text"* ]]
}
