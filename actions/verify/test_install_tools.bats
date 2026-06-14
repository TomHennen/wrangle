#!/usr/bin/env bats

# Behavioral test for install_tools.sh: ampel + bnd are always built; cosign is
# built only when OCI_TARGET is set (the container build pushes the VSA
# referrer). A fake `go` records the packages it was asked to install.

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    TEST_DIR="$(mktemp -d)"
    export DIR TEST_DIR

    GO_RECORD="$TEST_DIR/go-install-record"
    : > "$GO_RECORD"
    FAKE_BIN="$TEST_DIR/fakebin"
    mkdir -p "$FAKE_BIN"
    export GO_RECORD FAKE_BIN
    cat > "$FAKE_BIN/go" << 'FAKEGO'
#!/usr/bin/env bash
set -euo pipefail
pkgs=()
seen_install=0
while [ $# -gt 0 ]; do
    case "$1" in
        -C) shift 2; continue ;;
        install) seen_install=1; shift; continue ;;
        *) [ "$seen_install" -eq 1 ] && pkgs+=("$1"); shift ;;
    esac
done
[ "${#pkgs[@]}" -gt 0 ] && printf '%s\n' "${pkgs[@]}" >> "$GO_RECORD"
exit 0
FAKEGO
    chmod +x "$FAKE_BIN/go"

    # Keep the installed-binary check from touching the real tree.
    export WRANGLE_BIN_DIR="$TEST_DIR/bin"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "install_tools.sh: without OCI_TARGET builds ampel+bnd, not cosign" {
    PATH="$FAKE_BIN:$PATH" run "$DIR/install_tools.sh"
    [ "$status" -eq 0 ]
    grep -Fq 'github.com/carabiner-dev/ampel/cmd/ampel' "$GO_RECORD"
    grep -Fq 'github.com/carabiner-dev/bnd' "$GO_RECORD"
    ! grep -Fq 'cosign' "$GO_RECORD"
}

@test "install_tools.sh: with OCI_TARGET also builds cosign" {
    OCI_TARGET="ghcr.io/x/y@sha256:abc" PATH="$FAKE_BIN:$PATH" run "$DIR/install_tools.sh"
    [ "$status" -eq 0 ]
    grep -Fq 'github.com/carabiner-dev/ampel/cmd/ampel' "$GO_RECORD"
    grep -Fq 'github.com/carabiner-dev/bnd' "$GO_RECORD"
    grep -Fq 'github.com/sigstore/cosign/v3/cmd/cosign' "$GO_RECORD"
}
