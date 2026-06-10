#!/usr/bin/env bats

# Tests for tools/wrangle-doc-lint/lint.sh — the `→ enforced by:` pointer
# validator for spec docs.
#
# Layout: fixtures/root/ is a miniature repo (a bats file, a lib script, a
# rule-definition file) and fixtures/docs/ holds one doc per WDL rule plus
# good.md as the negative fixture. The final test runs the default
# invocation against the real docs/SPEC.md — the live wiring `make
# docstyle` exercises, and the canary that fails when a cited test is
# renamed or deleted.

setup() {
    ORIG_DIR="$(pwd)"
    LINTER="$ORIG_DIR/tools/wrangle-doc-lint/lint.sh"
    ROOT="$ORIG_DIR/tools/wrangle-doc-lint/fixtures/root"
    DOCS="$ORIG_DIR/tools/wrangle-doc-lint/fixtures/docs"
    export ORIG_DIR LINTER ROOT DOCS

    # Mandatory in CI and in the test image; fail loud rather than skip.
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'python3 not on PATH — run via ./test.sh (the Docker image provides it)\n' >&2
        return 1
    fi
}

@test "doc-lint: clean doc passes with no output" {
    run "$LINTER" --root "$ROOT" "$DOCS/good.md"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "doc-lint: WDL001 on missing bats file and missing script" {
    run "$LINTER" --root "$ROOT" "$DOCS/bad_missing_file.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WDL001"*"tools/demo/gone.bats"* ]]
    [[ "$output" == *"WDL001"*"lib/gone.sh"* ]]
}

@test "doc-lint: WDL002 on missing @test name" {
    run "$LINTER" --root "$ROOT" "$DOCS/bad_missing_test.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WDL002"*"demo: this name was renamed"* ]]
}

@test "doc-lint: WDL003 on unknown rule ID" {
    run "$LINTER" --root "$ROOT" "$DOCS/bad_unknown_rule.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WDL003"*"WSL999"* ]]
}

@test "doc-lint: WDL004 on pointer with no recognizable check" {
    run "$LINTER" --root "$ROOT" "$DOCS/bad_no_ref.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WDL004"* ]]
}

@test "doc-lint: violations report file and line number" {
    run "$LINTER" --root "$ROOT" "$DOCS/bad_missing_test.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bad_missing_test.md:2:"* ]]
}

@test "doc-lint: nonexistent root is a tool error (exit 2)" {
    run "$LINTER" --root "$ROOT/no-such-dir" "$DOCS/good.md"
    [ "$status" -eq 2 ]
}

@test "doc-lint: default invocation validates the real docs/SPEC.md" {
    cd "$ORIG_DIR"
    run "$LINTER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
