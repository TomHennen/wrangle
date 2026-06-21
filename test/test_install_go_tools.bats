#!/usr/bin/env bats

# Behavioral test for lib/install_go_tools.sh — the shared `go install` helper
# both the verify and attest jobs delegate to. A fake `go` records the package
# paths it was asked to build; the helper must pass exactly its arguments and
# build from tools/go.mod.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/lib/install_go_tools.sh"
    TEST_DIR="$(mktemp -d)"
    export REPO_ROOT SCRIPT TEST_DIR

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

@test "install_go_tools.sh: builds exactly the requested packages" {
    PATH="$FAKE_BIN:$PATH" run "$SCRIPT" \
        github.com/TomHennen/wrangle/tools/wrangle-attest \
        github.com/carabiner-dev/bnd
    [ "$status" -eq 0 ]
    grep -Fqx 'github.com/TomHennen/wrangle/tools/wrangle-attest' "$GO_RECORD"
    grep -Fqx 'github.com/carabiner-dev/bnd' "$GO_RECORD"
    # No ampel or cosign unless asked.
    ! grep -Fq 'ampel' "$GO_RECORD"
    ! grep -Fq 'cosign' "$GO_RECORD"
}

@test "install_go_tools.sh: rejects an empty package set" {
    PATH="$FAKE_BIN:$PATH" run "$SCRIPT"
    [ "$status" -ne 0 ]
}
