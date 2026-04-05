#!/usr/bin/env bats

# Tests for lib/sanitize.sh (wrangle_sanitize_output)

setup() {
    export ORIG_DIR="$(pwd)"
    source "$ORIG_DIR/lib/sanitize.sh"
}

@test "sanitize: strips script tags" {
    result="$(printf '<script>alert("xss")</script>Safe text' | wrangle_sanitize_output)"

    [[ "$result" == *"Safe text"* ]]
    [[ "$result" != *"<script>"* ]]
    [[ "$result" != *"</script>"* ]]
}

@test "sanitize: strips img tags with event handlers" {
    result="$(printf '<img src=x onerror=alert(1)>Content' | wrangle_sanitize_output)"

    [[ "$result" == *"Content"* ]]
    [[ "$result" != *"<img"* ]]
    [[ "$result" != *"onerror"* ]]
}

@test "sanitize: strips nested HTML tags" {
    result="$(printf '<div><b>bold</b></div>' | wrangle_sanitize_output)"

    [[ "$result" == "bold" ]]
}

@test "sanitize: passes plain text through unchanged" {
    result="$(printf 'No HTML here, just text.' | wrangle_sanitize_output)"

    [[ "$result" == "No HTML here, just text." ]]
}

@test "sanitize: truncates output to MAX_SUMMARY_LENGTH" {
    export WRANGLE_MAX_SUMMARY=10
    source "$ORIG_DIR/lib/sanitize.sh"

    result="$(printf 'abcdefghijklmnopqrstuvwxyz' | wrangle_sanitize_output)"

    [[ ${#result} -eq 10 ]]
    [[ "$result" == "abcdefghij" ]]
}

@test "sanitize: uses default 65536 limit" {
    # Verify the default is set (don't generate 64KB of data, just check the var)
    [[ "$MAX_SUMMARY_LENGTH" == "65536" ]]
}
