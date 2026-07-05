#!/usr/bin/env bats

# Unit tests for lib/resolve_subjects.sh functions (the attest/verify jobs
# source this and call them). Hermetic — no real signing tools.

setup() {
    LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/resolve_subjects.sh"
    TEST_DIR="$(mktemp -d)"
    GITHUB_OUTPUT="$TEST_DIR/gh_output"; : > "$GITHUB_OUTPUT"
    export TEST_DIR GITHUB_OUTPUT
}

teardown() { rm -rf "$TEST_DIR"; }

@test "resolve_glob: a non-file match sorting last does not abort (set -e safe)" {
    # A subdirectory sorts after the .tgz, so it is the last glob match; the
    # resolver must skip it and still list the real file, not return 1.
    mkdir -p "$TEST_DIR/d/zz-subdir"; : > "$TEST_DIR/d/app.tgz"
    run bash -c "set -euo pipefail; source '$LIB'; WRANGLE_RESOLVED=(); wrangle_resolve_glob '$TEST_DIR/d/*'; printf '%s\n' \"\${WRANGLE_RESOLVED[@]}\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"d/app.tgz"* ]]
    [[ "$output" != *"zz-subdir"* ]]
}

@test "resolve_checksums: a file with no trailing newline lists its last entry" {
    printf '%s  %s\n%s  %s' aaa first.tgz bbb last.tgz > "$TEST_DIR/checksums.txt"
    run bash -c "set -euo pipefail; source '$LIB'; DIST_DIR=dist; WRANGLE_RESOLVED=(); wrangle_resolve_checksums '$TEST_DIR/checksums.txt'; printf '%s\n' \"\${WRANGLE_RESOLVED[@]}\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"dist/first.tgz"* ]]
    [[ "$output" == *"dist/last.tgz"* ]]
}

@test "emit_subjects: an empty resolved set fails closed with a message" {
    run bash -c "set -euo pipefail; source '$LIB'; WRANGLE_RESOLVED=(); wrangle_emit_subjects"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no subject files resolved"* ]]
}
