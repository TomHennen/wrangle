#!/usr/bin/env bats

# Behavioral test for actions/attest_metadata_oci/install_tools.sh: the container
# attest job signs metadata AND pushes OCI referrers, so it builds wrangle-attest
# (statements) + bnd (sign + store push) + cosign (OCI referrer push) — never
# ampel (no verdict here). A fake `go` records the packages.

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
    export WRANGLE_BIN_DIR="$TEST_DIR/bin"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "attest_metadata_oci install_tools.sh: builds wrangle-attest + bnd + cosign, not ampel" {
    PATH="$FAKE_BIN:$PATH" run "$DIR/install_tools.sh"
    [ "$status" -eq 0 ]
    grep -Fq 'github.com/TomHennen/wrangle/tools/wrangle-attest' "$GO_RECORD"
    grep -Fq 'github.com/carabiner-dev/bnd' "$GO_RECORD"
    grep -Fq 'github.com/sigstore/cosign/v3/cmd/cosign' "$GO_RECORD"
    ! grep -Fq 'ampel' "$GO_RECORD"
}
