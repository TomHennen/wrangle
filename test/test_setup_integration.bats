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

@test "setup_integration: installs all Go tools from tools/go.mod" {
    # One `go install tool` covers ampel, bnd, cosign, and osv-scanner —
    # the tool directives in tools/go.mod are the single version source.
    run grep -F 'go -C "$REPO_ROOT/tools" install tool' "$SETUP"
    [ "$status" -eq 0 ]
}

@test "setup_integration: guards the Go tool install with a go.sum-digest stamp" {
    # A restored CI binary cache (build_shell.yml cache-setup-tools) must skip
    # the rebuild: the install runs only when the stamp is absent or stale.
    run grep -F '.go-tools.stamp' "$SETUP"
    [ "$status" -eq 0 ]
}

@test "setup_integration: the dogfood workflow caches the installed Go tools" {
    # local_build_shell.yml opts into the binary cache so go.sum-stable runs
    # don't relink ampel/bnd/cosign/osv-scanner.
    run grep -E 'cache-setup-tools:[[:space:]]*enabled' "$REPO_ROOT/.github/workflows/local_build_shell.yml"
    [ "$status" -eq 0 ]
}

@test "setup_integration: the dogfood workflow auto-detects bats (no explicit list)" {
    # CI coverage must not depend on a hand-maintained file list: with
    # bats-path unset, build_shell auto-detects every .bats in the tree.
    # (Makefile INTEGRATION_BATS remains a local-only convenience subset.)
    run grep 'bats-path:' "$REPO_ROOT/.github/workflows/local_build_shell.yml"
    [ "$status" -ne 0 ]
}

