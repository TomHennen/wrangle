#!/usr/bin/env bats

# Tests for run.sh (orchestrator)
# Uses mock tool directories with mock install/adapter scripts.

setup() {
    export TEST_DIR="$(mktemp -d)"
    export ORIG_DIR="$(pwd)"

    # Create a mock tools directory structure that run.sh can find
    export MOCK_TOOLS="$TEST_DIR/tools"

    # Create a clean tool (exit 0)
    mkdir -p "$MOCK_TOOLS/clean-tool"
    cat > "$MOCK_TOOLS/clean-tool/install.sh" << 'INST'
#!/bin/bash
set -euo pipefail
printf 'wrangle: installed clean-tool\n'
exit 0
INST
    chmod +x "$MOCK_TOOLS/clean-tool/install.sh"

    cat > "$MOCK_TOOLS/clean-tool/adapter.sh" << 'ADAPT'
#!/bin/bash
set -euo pipefail
cat > "$2/output.sarif" << 'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"clean-tool"}},"results":[]}]}
SARIF
exit 0
ADAPT
    chmod +x "$MOCK_TOOLS/clean-tool/adapter.sh"

    # Create a findings tool (exit 1)
    mkdir -p "$MOCK_TOOLS/findings-tool"
    cat > "$MOCK_TOOLS/findings-tool/install.sh" << 'INST'
#!/bin/bash
set -euo pipefail
printf 'wrangle: installed findings-tool\n'
exit 0
INST
    chmod +x "$MOCK_TOOLS/findings-tool/install.sh"

    cat > "$MOCK_TOOLS/findings-tool/adapter.sh" << 'ADAPT'
#!/bin/bash
set -euo pipefail
cat > "$2/output.sarif" << 'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"findings-tool"}},"results":[{"ruleId":"TEST-1","message":{"text":"found"}}]}]}
SARIF
exit 1
ADAPT
    chmod +x "$MOCK_TOOLS/findings-tool/adapter.sh"

    # Create an error tool (exit 2)
    mkdir -p "$MOCK_TOOLS/error-tool"
    cat > "$MOCK_TOOLS/error-tool/install.sh" << 'INST'
#!/bin/bash
set -euo pipefail
printf 'wrangle: installed error-tool\n'
exit 0
INST
    chmod +x "$MOCK_TOOLS/error-tool/install.sh"

    cat > "$MOCK_TOOLS/error-tool/adapter.sh" << 'ADAPT'
#!/bin/bash
set -euo pipefail
exit 2
ADAPT
    chmod +x "$MOCK_TOOLS/error-tool/adapter.sh"

    # Create a tool with failing install
    mkdir -p "$MOCK_TOOLS/bad-install"
    cat > "$MOCK_TOOLS/bad-install/install.sh" << 'INST'
#!/bin/bash
set -euo pipefail
printf 'wrangle: install failed\n' >&2
exit 1
INST
    chmod +x "$MOCK_TOOLS/bad-install/install.sh"

    cat > "$MOCK_TOOLS/bad-install/adapter.sh" << 'ADAPT'
#!/bin/bash
exit 0
ADAPT
    chmod +x "$MOCK_TOOLS/bad-install/adapter.sh"

    # Create a slow tool for timeout testing
    mkdir -p "$MOCK_TOOLS/slow-tool"
    cat > "$MOCK_TOOLS/slow-tool/install.sh" << 'INST'
#!/bin/bash
set -euo pipefail
printf 'wrangle: installed slow-tool\n'
exit 0
INST
    chmod +x "$MOCK_TOOLS/slow-tool/install.sh"

    cat > "$MOCK_TOOLS/slow-tool/adapter.sh" << 'ADAPT'
#!/bin/bash
set -euo pipefail
sleep 30
exit 0
ADAPT
    chmod +x "$MOCK_TOOLS/slow-tool/adapter.sh"

    # Create a tool with slow install for timeout testing
    mkdir -p "$MOCK_TOOLS/slow-install"
    cat > "$MOCK_TOOLS/slow-install/install.sh" << 'INST'
#!/bin/bash
set -euo pipefail
sleep 30
exit 0
INST
    chmod +x "$MOCK_TOOLS/slow-install/install.sh"

    cat > "$MOCK_TOOLS/slow-install/adapter.sh" << 'ADAPT'
#!/bin/bash
exit 0
ADAPT
    chmod +x "$MOCK_TOOLS/slow-install/adapter.sh"

    # Create test source and output directories
    mkdir -p "$TEST_DIR/src" "$TEST_DIR/output"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

# Helper: run the orchestrator with WRANGLE_TOOLS_DIR pointing to our mocks
run_orchestrator() {
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" "$@"
}

# --- Input validation tests ---

@test "orchestrator: rejects tool name with path traversal" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "../etc/passwd"

    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid tool name"* ]]
}

@test "orchestrator: rejects tool name with semicolon" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "foo;curl"

    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid tool name"* ]]
}

@test "orchestrator: rejects tool name with uppercase" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "FooBar"

    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid tool name"* ]]
}

@test "orchestrator: rejects tool name starting with number" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "1tool"

    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid tool name"* ]]
}

@test "orchestrator: accepts valid tool names" {
    # Valid: lowercase, starts with letter, may contain digits/hyphens/underscores
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool"

    [ "$status" -eq 0 ]
}

@test "orchestrator: rejects nonexistent tool" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "nonexistent"

    [ "$status" -eq 2 ]
}

# --- Execution tests ---

@test "orchestrator: runs clean tool (exit 0)" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/clean-tool/output.sarif" ]
}

@test "orchestrator: runs findings tool (exit 1)" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "findings-tool"

    [ "$status" -eq 1 ]
    [ -f "$TEST_DIR/output/findings-tool/output.sarif" ]
}

@test "orchestrator: runs error tool (exit 2)" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "error-tool"

    [ "$status" -eq 2 ]
}

@test "orchestrator: handles install failure (exit 2)" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "bad-install"

    [ "$status" -eq 2 ]
}

@test "orchestrator: runs multiple tools" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool" "findings-tool"

    # Findings from one tool means exit 1
    [ "$status" -eq 1 ]
    [ -f "$TEST_DIR/output/clean-tool/output.sarif" ]
    [ -f "$TEST_DIR/output/findings-tool/output.sarif" ]
}

@test "orchestrator: error takes precedence over findings" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool" "error-tool"

    [ "$status" -eq 2 ]
}

@test "orchestrator: prints summary table" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool"

    [[ "$output" == *"clean-tool"* ]]
}

# --- Default options tests ---

@test "orchestrator: uses default src_dir and output_dir" {
    cd "$TEST_DIR/src"
    mkdir -p metadata
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" "clean-tool"

    [ "$status" -eq 0 ]
}

@test "orchestrator: no tools provided prints usage" {
    run_orchestrator

    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"usage"* ]]
}

# --- Path resolution tests ---

# --- Timeout tests ---

@test "orchestrator: adapter timeout produces exit 2" {
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" WRANGLE_ADAPTER_TIMEOUT=1 \
        run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "slow-tool"

    [ "$status" -eq 2 ]
    [[ "$output" == *"timed out"* ]]
}

@test "orchestrator: install timeout produces exit 2" {
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" WRANGLE_INSTALL_TIMEOUT=1 \
        run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "slow-install"

    [ "$status" -eq 2 ]
    [[ "$output" == *"timed out"* ]]
}

# --- Path resolution tests ---

@test "orchestrator: resolves tool paths relative to script, not cwd" {
    # Run from a different directory than the script
    cd "$TEST_DIR"
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool"

    [ "$status" -eq 0 ]
}
