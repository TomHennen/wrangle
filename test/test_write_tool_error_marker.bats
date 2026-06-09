#!/usr/bin/env bats

# Tests for lib/write_tool_error_marker.sh (wrangle_write_tool_error_marker)

setup() {
    ORIG_DIR="$(pwd)"
    export ORIG_DIR
    TMPDIR_TEST="$(mktemp -d)"
    source "$ORIG_DIR/lib/write_tool_error_marker.sh"
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

@test "write_tool_error_marker: writes message + newline to <metadata_dir>/error" {
    wrangle_write_tool_error_marker "$TMPDIR_TEST" "upstream tool failed"

    [[ -f "$TMPDIR_TEST/error" ]]
    # Exact content: message + single trailing newline.
    printf '%s\n' "upstream tool failed" > "$TMPDIR_TEST/expected"
    cmp -s "$TMPDIR_TEST/error" "$TMPDIR_TEST/expected"
}

@test "write_tool_error_marker: creates non-existent metadata dir" {
    dir="$TMPDIR_TEST/does/not/exist/yet"
    [[ ! -d "$dir" ]]

    wrangle_write_tool_error_marker "$dir" "msg"

    [[ -d "$dir" ]]
    [[ -f "$dir/error" ]]
}

@test "write_tool_error_marker: overwrites existing marker" {
    wrangle_write_tool_error_marker "$TMPDIR_TEST" "first"
    wrangle_write_tool_error_marker "$TMPDIR_TEST" "second"

    [[ "$(cat "$TMPDIR_TEST/error")" == "second" ]]
}

@test "write_tool_error_marker: preserves message verbatim (no shell expansion)" {
    # $TMPDIR_TEST should NOT be expanded; the printf '%s' form passes
    # the message through literally.
    wrangle_write_tool_error_marker "$TMPDIR_TEST" 'literal $VAR and *glob*'

    [[ "$(cat "$TMPDIR_TEST/error")" == 'literal $VAR and *glob*' ]]
}
