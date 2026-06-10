#!/usr/bin/env bats

# Tests for the slsa-verifier installer.
#
# slsa-verifier installs as the official release binary with hardcoded
# per-arch checksums — NOT as a tools/go.mod tool directive. Building it
# from a Dependabot-refreshed graph would produce a verifier upstream
# never tested, and carrying its frozen go.mod in-tree advertises every
# since-published advisory in that year-old graph to source scanners
# with nothing to bump. The full rationale lives in install.sh.

setup() {
    TOOL_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slsa-verifier-bats-XXXXXX")"
}

teardown() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

@test "slsa-verifier install: exists, executable, parses" {
    [[ -x "$TOOL_DIR/install.sh" ]]
    run bash -n "$TOOL_DIR/install.sh"
    [ "$status" -eq 0 ]
}

@test "slsa-verifier install: sources download_verify library" {
    run grep -F 'source "${SCRIPT_DIR}/../../lib/download_verify.sh"' "$TOOL_DIR/install.sh"
    [ "$status" -eq 0 ]
}

@test "slsa-verifier install: hardcodes a checksum per architecture" {
    run grep -cE '^CHECKSUM_(AMD64|ARM64)="[0-9a-f]{64}"$' "$TOOL_DIR/install.sh"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

@test "slsa-verifier install: skips if correct version already installed" {
    mkdir -p "$TMP_DIR/bin"
    printf '#!/bin/bash\nprintf "GitVersion:    2.7.1\\n"\n' > "$TMP_DIR/bin/slsa-verifier"
    chmod +x "$TMP_DIR/bin/slsa-verifier"
    WRANGLE_BIN_DIR="$TMP_DIR/bin" run "$TOOL_DIR/install.sh" "2.7.1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

@test "slsa-verifier: stays out of tools/go.mod (frozen upstream graph)" {
    run grep -F 'slsa-verifier' "$REPO_ROOT/tools/go.mod"
    [ "$status" -ne 0 ]
}

@test "slsa-verifier: no go.mod here either — binary install only" {
    [ ! -f "$TOOL_DIR/go.mod" ]
}
