#!/usr/bin/env bats

# Tests for tools/syft/install.sh.
# Uses mock curl + cosign to keep tests fast and deterministic.

setup() {
    TEST_DIR="$(mktemp -d)"
    ORIG_DIR="$(pwd)"
    export TEST_DIR ORIG_DIR
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/install_bin"
    export WRANGLE_BIN_DIR="$TEST_DIR/install_bin"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "syft install: script parses cleanly" {
    run bash -n "$ORIG_DIR/tools/syft/install.sh"
    [ "$status" -eq 0 ]
}

@test "syft install: skips if correct version already installed" {
    cat > "$WRANGLE_BIN_DIR/syft" << 'MOCK'
#!/bin/bash
printf '{"application":"syft","version":"1.42.4","buildDate":""}'
MOCK
    chmod +x "$WRANGLE_BIN_DIR/syft"

    run "$ORIG_DIR/tools/syft/install.sh" "1.42.4"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

@test "syft install: fails fast if cosign is not on PATH" {
    # Mock curl to return any content (so download succeeds), then ensure
    # cosign is not findable. install.sh must abort before tarball download.
    cat > "$TEST_DIR/bin/curl" << 'MOCK'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in
        -o) echo "stub" > "$2"; shift 2 ;;
        *) shift ;;
    esac
done
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/curl"
    # Empty PATH so cosign is not found, but keep coreutils available.
    PATH="$TEST_DIR/bin:/usr/bin:/bin" run "$ORIG_DIR/tools/syft/install.sh" "1.42.4"

    [ "$status" -eq 1 ]
    [[ "$output" == *"cosign not found"* ]]
}

@test "syft install: fails if checksum download fails" {
    cat > "$TEST_DIR/bin/curl" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/curl"

    PATH="$TEST_DIR/bin:$PATH" run "$ORIG_DIR/tools/syft/install.sh" "1.42.4"

    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"checksums"* ]]
    [ ! -f "$WRANGLE_BIN_DIR/syft" ]
}

@test "syft install: aborts when cosign verification fails" {
    cat > "$TEST_DIR/bin/curl" << 'MOCK'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in
        -o) echo "tampered content" > "$2"; shift 2 ;;
        *) shift ;;
    esac
done
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/curl"

    cat > "$TEST_DIR/bin/cosign" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/cosign"

    PATH="$TEST_DIR/bin:$PATH" run "$ORIG_DIR/tools/syft/install.sh" "1.42.4"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Cosign signature verification failed"* ]]
    [ ! -f "$WRANGLE_BIN_DIR/syft" ]
}

@test "syft install: aborts when binary not listed in checksums" {
    cat > "$TEST_DIR/bin/curl" << 'MOCK'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
# Write a checksums.txt that lacks the platform tarball line.
case "$out" in
    *checksums.txt) printf 'deadbeef  some-other-file\n' > "$out" ;;
    *) echo "stub" > "$out" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/curl"

    cat > "$TEST_DIR/bin/cosign" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/cosign"

    PATH="$TEST_DIR/bin:$PATH" run "$ORIG_DIR/tools/syft/install.sh" "1.42.4"

    [ "$status" -eq 1 ]
    [[ "$output" == *"not listed in checksums.txt"* ]]
    [ ! -f "$WRANGLE_BIN_DIR/syft" ]
}

@test "syft install: pins to anchore/syft release.yaml on main in cosign identity" {
    # Structural check: trust is locked to anchore/syft's release.yaml
    # workflow on its main branch (Anchore's release process is "push tag,
    # release.yaml signs from main"). Changing this requires a deliberate
    # decision — it widens or narrows what cosign will accept.
    run grep -F 'anchore/syft/.github/workflows/release.yaml@refs/heads/main' "$ORIG_DIR/tools/syft/install.sh"
    [ "$status" -eq 0 ]
}

@test "syft install: no curl | sh, no /usr/local/bin" {
    # Wrangle's supply-chain rules: no curl-pipe-shell, no system bindir.
    run grep -E 'curl[^|]*\| *sh|/usr/local/bin' "$ORIG_DIR/tools/syft/install.sh"
    [ "$status" -ne 0 ]
}

@test "syft install: uses WRANGLE_BIN_DIR" {
    run grep 'WRANGLE_BIN_DIR' "$ORIG_DIR/tools/syft/install.sh"
    [ "$status" -eq 0 ]
}
