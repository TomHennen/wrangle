#!/usr/bin/env bats

# Tests for lib/install_go_tool.sh — the generic installer behind
# tools/<name>/go-tool markers. The rejection paths run before any go
# invocation, so they are hermetic; a real install runs in
# ./test.sh integration and the dogfooded shell build.

setup() {
    ORIG_DIR="$(pwd)"
    export ORIG_DIR
    INSTALL="$ORIG_DIR/lib/install_go_tool.sh"
}

@test "install_go_tool: exists, executable, parses" {
    [[ -x "$INSTALL" ]]
    run bash -n "$INSTALL"
    [ "$status" -eq 0 ]
}

@test "install_go_tool: usage error with no args" {
    run "$INSTALL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "install_go_tool: rejects a package path with a hostile charset" {
    run "$INSTALL" 'github.com/x;rm -rf /'
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid go tool package path"* ]]
}

@test "install_go_tool: rejects a package not declared in tools/go.mod" {
    run "$INSTALL" "github.com/evil/not-a-declared-tool/cmd/x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a tool directive in tools/go.mod"* ]]
}

@test "install_go_tool: pins GOPROXY and GOSUMDB at the install site" {
    grep -q 'export GOPROXY="https://proxy.golang.org,direct"' "$INSTALL"
    grep -q 'export GOSUMDB="sum.golang.org"' "$INSTALL"
}
