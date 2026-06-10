#!/usr/bin/env bats

# Structural tests for test/setup_integration.sh and the integration
# wiring around it. The script's real behavior (installing the tools) is
# exercised by `./test.sh integration` and by wrangle's own
# local_build_shell.yml run — both non-hermetic by design.

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    SETUP="$REPO_ROOT/test/setup_integration.sh"
}

@test "setup_integration: exists, executable, parses" {
    [[ -x "$SETUP" ]]
    run bash -n "$SETUP"
    [ "$status" -eq 0 ]
}

@test "setup_integration: sources lib/env.sh for WRANGLE_BIN_DIR and GOPROXY/GOSUMDB pins" {
    run grep -F 'source "$REPO_ROOT/lib/env.sh"' "$SETUP"
    [ "$status" -eq 0 ]
}

@test "setup_integration: installs slsa-verifier before osv-scanner" {
    # osv install.sh needs slsa-verifier on PATH for provenance
    # verification, so its install must appear before the osv line.
    local sv_line osv_line
    sv_line="$(grep -nF '"$REPO_ROOT/tools/slsa-verifier/install.sh"' "$SETUP" | head -1 | cut -d: -f1)"
    osv_line="$(grep -nF '"$REPO_ROOT/tools/osv/install.sh"' "$SETUP" | head -1 | cut -d: -f1)"
    [[ -n "$sv_line" && -n "$osv_line" ]]
    [[ "$sv_line" -lt "$osv_line" ]]
}

@test "setup_integration: workflow bats-path matches Makefile INTEGRATION_BATS" {
    # The integration bats list lives in two artifact types that can't share
    # a definition: the Makefile (make integration) and the reusable-workflow
    # input in local_build_shell.yml. Fail on divergence.
    local mk wf
    mk="$(grep '^INTEGRATION_BATS :=' "$REPO_ROOT/Makefile" | sed 's/^INTEGRATION_BATS := //')"
    wf="$(grep 'bats-path:' "$REPO_ROOT/.github/workflows/local_build_shell.yml" | sed 's/.*bats-path: *"//; s/" *$//')"
    [[ -n "$mk" && -n "$wf" ]]
    [[ "$mk" == "$wf" ]]
}

@test "setup_integration: workflow passes scan-tools explicitly" {
    run grep -E 'scan-tools: *"osv ' "$REPO_ROOT/.github/workflows/local_build_shell.yml"
    [ "$status" -eq 0 ]
}
