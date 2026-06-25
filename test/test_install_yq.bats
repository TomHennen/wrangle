#!/usr/bin/env bats

# Tests for lib/install_yq.sh — orchestrator infra installed onto every
# adopter's PATH by setup.sh. A mock curl keeps the download layer offline and
# deterministic; the checksum-mismatch test uses the real hardcoded pin so the
# fail-closed assertion has teeth.

setup() {
    TEST_DIR="$(mktemp -d)"
    ORIG_DIR="$(pwd)"
    export TEST_DIR ORIG_DIR
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/install_bin"
    export WRANGLE_BIN_DIR="$TEST_DIR/install_bin"
    PINNED_VERSION="4.53.3"
    export PINNED_VERSION

    # No real network here, so download_verify's inter-attempt backoff is dead
    # time; a no-op sleep keeps the retry-exhaustion paths fast.
    cat > "$TEST_DIR/bin/sleep" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/sleep"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "install_yq: script parses cleanly" {
    run bash -n "$ORIG_DIR/lib/install_yq.sh"
    [ "$status" -eq 0 ]
}

@test "install_yq: checksum mismatch fails closed and leaves no binary" {
    # curl serves content whose hash will not match the hardcoded pin.
    echo "tampered yq binary" > "$TEST_DIR/payload"
    cat > "$TEST_DIR/bin/curl" << MOCK
#!/bin/bash
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
cp "$TEST_DIR/payload" "\$out"
MOCK
    chmod +x "$TEST_DIR/bin/curl"

    PATH="$TEST_DIR/bin:$PATH" run "$ORIG_DIR/lib/install_yq.sh" "$PINNED_VERSION"

    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    # The security-critical assertion: no yq binary is left behind.
    [ ! -e "$WRANGLE_BIN_DIR/yq" ]
}

@test "install_yq: clean install lands an executable yq in WRANGLE_BIN_DIR" {
    # Serve a real payload and pin a copied installer to that payload's actual
    # hash, so the genuine wrangle_download_verify checksum gate stays in the
    # loop while the test stays offline (no preimage forgery).
    cat > "$TEST_DIR/payload" << 'YQ'
#!/bin/bash
echo "yq (https://github.com/mikefarah/yq/) version v4.53.3"
YQ
    cat > "$TEST_DIR/bin/curl" << MOCK
#!/bin/bash
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
cp "$TEST_DIR/payload" "\$out"
MOCK
    chmod +x "$TEST_DIR/bin/curl"

    local sha inst
    sha="$(sha256sum "$TEST_DIR/payload" | cut -d' ' -f1)"
    inst="$TEST_DIR/install_yq.sh"
    cp "$ORIG_DIR/lib/install_yq.sh" "$inst"
    cp "$ORIG_DIR/lib/download_verify.sh" "$TEST_DIR/download_verify.sh"
    sed -i -E "s/^SHA256_AMD64=\"[0-9a-f]{64}\"/SHA256_AMD64=\"$sha\"/" "$inst"
    sed -i -E "s/^SHA256_ARM64=\"[0-9a-f]{64}\"/SHA256_ARM64=\"$sha\"/" "$inst"

    PATH="$TEST_DIR/bin:$PATH" run "$inst" "$PINNED_VERSION"

    [ "$status" -eq 0 ]
    [ -x "$WRANGLE_BIN_DIR/yq" ]
    [[ "$output" == *"installed yq"* ]]
}

@test "install_yq: skips re-download if requested version already installed" {
    cat > "$WRANGLE_BIN_DIR/yq" << 'MOCK'
#!/bin/bash
echo "yq (https://github.com/mikefarah/yq/) version v4.53.3"
MOCK
    chmod +x "$WRANGLE_BIN_DIR/yq"

    # curl that fails loudly: if the installer tries to download, the test fails.
    cat > "$TEST_DIR/bin/curl" << 'MOCK'
#!/bin/bash
echo "curl should not run on idempotent skip" >&2
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/curl"

    PATH="$TEST_DIR/bin:$PATH" run "$ORIG_DIR/lib/install_yq.sh" "$PINNED_VERSION"

    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

@test "install_yq: rejects unsupported architecture" {
    cat > "$TEST_DIR/bin/uname" << 'MOCK'
#!/bin/bash
echo "mips64"
MOCK
    chmod +x "$TEST_DIR/bin/uname"

    PATH="$TEST_DIR/bin:$PATH" run "$ORIG_DIR/lib/install_yq.sh" "$PINNED_VERSION"

    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported architecture"* ]]
    [ ! -e "$WRANGLE_BIN_DIR/yq" ]
}

@test "install_yq: no curl | sh, no /usr/local/bin" {
    # Wrangle supply-chain rules: downloads route through wrangle_download_verify,
    # not curl-pipe-shell, and never into a system bindir.
    run grep -E 'curl[^|]*\| *sh|/usr/local/bin' "$ORIG_DIR/lib/install_yq.sh"
    [ "$status" -ne 0 ]
}

@test "install_yq: downloads through wrangle_download_verify" {
    run grep -F 'wrangle_download_verify' "$ORIG_DIR/lib/install_yq.sh"
    [ "$status" -eq 0 ]
}

@test "install_yq: installs into WRANGLE_BIN_DIR" {
    run grep 'WRANGLE_BIN_DIR' "$ORIG_DIR/lib/install_yq.sh"
    [ "$status" -eq 0 ]
}
