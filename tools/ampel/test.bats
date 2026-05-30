#!/usr/bin/env bats

# Tests for tools/ampel/install.sh — verification-chain control flow.
#
# ampel is an install-only tool (no adapter): the verify stage invokes the
# binary directly, so there is no adapter.sh/render_md.sh to test. These
# tests shim curl and slsa-verifier so no real download or signature check
# happens — they cover the exit-code contract, the no-install-on-failure
# guarantee, and that the attest-build-provenance --builder-id is forwarded.
#
# The live verification path (slsa-verifier against the real ampel sigstore
# bundle) is exercised when the scan action runs ampel's installer on a real
# runner in CI, where sigstore's TUF root is reachable.

setup() {
    ORIG_DIR="$(pwd)"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ampel-bats-XXXXXX")"
    INSTALL="$ORIG_DIR/tools/ampel/install.sh"
    export ORIG_DIR TMP_DIR INSTALL
    mkdir -p "$TMP_DIR/bin"
}

teardown() {
    cd "$ORIG_DIR" || true
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

@test "ampel install: script parses" {
    run bash -n "$INSTALL"
    [ "$status" -eq 0 ]
}

@test "ampel install: skips if correct version already installed" {
    export WRANGLE_BIN_DIR="$TMP_DIR/bin"
    cat > "$WRANGLE_BIN_DIR/ampel" <<'MOCK'
#!/bin/bash
[[ "$1" == "version" ]] && printf 'GitVersion:    v1.2.1\n'
MOCK
    chmod +x "$WRANGLE_BIN_DIR/ampel"

    run "$INSTALL" "1.2.1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

@test "ampel install: fails if binary download fails" {
    export WRANGLE_BIN_DIR="$TMP_DIR/bin"
    cat > "$TMP_DIR/curl" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TMP_DIR/curl"
    PATH="$TMP_DIR:$PATH"

    run "$INSTALL" "1.2.1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [ ! -f "$WRANGLE_BIN_DIR/ampel" ]
}

@test "ampel install: fails if provenance download fails" {
    export WRANGLE_BIN_DIR="$TMP_DIR/bin"
    printf '0\n' > "$TMP_DIR/curl_count"
    cat > "$TMP_DIR/curl" <<'MOCK'
#!/bin/bash
count=$(cat "$TMP_DIR/curl_count")
count=$((count + 1))
printf '%d\n' "$count" > "$TMP_DIR/curl_count"
# First call (binary) succeeds; second call (provenance) fails.
if [[ "$count" -eq 1 ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) printf 'fake binary\n' > "$2"; exit 0 ;;
            *) shift ;;
        esac
    done
fi
exit 1
MOCK
    chmod +x "$TMP_DIR/curl"
    PATH="$TMP_DIR:$PATH"

    run "$INSTALL" "1.2.1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"provenance"* ]]
    [ ! -f "$WRANGLE_BIN_DIR/ampel" ]
    leftover=$(find "$WRANGLE_BIN_DIR" -name 'wrangle-dl-*' -o -name '*.intoto.jsonl' 2>/dev/null | wc -l)
    [ "$leftover" -eq 0 ]
}

@test "ampel install: fails if provenance verification fails (no install)" {
    export WRANGLE_BIN_DIR="$TMP_DIR/bin"
    cat > "$TMP_DIR/curl" <<'MOCK'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) printf 'fake content\n' > "$2"; exit 0 ;;
        *) shift ;;
    esac
done
exit 0
MOCK
    chmod +x "$TMP_DIR/curl"
    cat > "$TMP_DIR/slsa-verifier" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TMP_DIR/slsa-verifier"
    PATH="$TMP_DIR:$PATH"

    run "$INSTALL" "1.2.1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"supply chain attack"* ]]
    [ ! -f "$WRANGLE_BIN_DIR/ampel" ]
}

@test "ampel install: verified binary is installed and --builder-id forwarded" {
    export WRANGLE_BIN_DIR="$TMP_DIR/bin"
    cat > "$TMP_DIR/curl" <<'MOCK'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) printf 'fake ampel binary\n' > "$2"; exit 0 ;;
        *) shift ;;
    esac
done
exit 0
MOCK
    chmod +x "$TMP_DIR/curl"
    # Record args so the test can assert the builder-id is passed through.
    cat > "$TMP_DIR/slsa-verifier" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "$TMP_DIR/slsa_args"
exit 0
MOCK
    chmod +x "$TMP_DIR/slsa-verifier"
    PATH="$TMP_DIR:$PATH"

    run "$INSTALL" "1.2.1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"provenance verified"* ]]
    [ -x "$WRANGLE_BIN_DIR/ampel" ]
    grep -q -- '--builder-id' "$TMP_DIR/slsa_args"
    grep -q 'carabiner-dev/ampel/.github/workflows/release.yaml@refs/tags/v1.2.1' "$TMP_DIR/slsa_args"
    # Temp artifacts cleaned up.
    leftover=$(find "$WRANGLE_BIN_DIR" -name 'wrangle-dl-*' -o -name '*.intoto.jsonl' 2>/dev/null | wc -l)
    [ "$leftover" -eq 0 ]
}
