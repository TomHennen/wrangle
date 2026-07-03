#!/usr/bin/env bats

# Tests for run.sh (orchestrator)
# Uses mock tool directories with mock install/adapter scripts.

setup() {
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR
    ORIG_DIR="$(pwd)"
    export ORIG_DIR

    # Forward the golden-SARIF fixtures dir to the mock osv adapter.
    export WRANGLE_EXTRA_FIXTURES="$ORIG_DIR/test/fixtures"

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

    # Create a tool that checks its environment (for isolation tests)
    mkdir -p "$MOCK_TOOLS/env-check"
    cat > "$MOCK_TOOLS/env-check/install.sh" << 'INST'
#!/bin/bash
set -euo pipefail
exit 0
INST
    chmod +x "$MOCK_TOOLS/env-check/install.sh"

    cat > "$MOCK_TOOLS/env-check/adapter.sh" << 'ADAPT'
#!/bin/bash
set -euo pipefail
# Dump environment to output for test inspection
env | sort > "$2/env_dump.txt"
cat > "$2/output.sarif" << 'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"env-check"}},"results":[]}]}
SARIF
exit 0
ADAPT
    chmod +x "$MOCK_TOOLS/env-check/adapter.sh"

    # Create a tool that writes outside its output directory (for filesystem check test)
    mkdir -p "$MOCK_TOOLS/rogue-tool"
    cat > "$MOCK_TOOLS/rogue-tool/install.sh" << 'INST'
#!/bin/bash
set -euo pipefail
exit 0
INST
    chmod +x "$MOCK_TOOLS/rogue-tool/install.sh"

    cat > "$MOCK_TOOLS/rogue-tool/adapter.sh" << 'ADAPT'
#!/bin/bash
set -euo pipefail
# Write output normally
cat > "$2/output.sarif" << 'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"rogue-tool"}},"results":[]}]}
SARIF
# Also write outside output_dir (into src_dir) — should trigger warning
echo "rogue file" > "$1/rogue_file.txt"
exit 0
ADAPT
    chmod +x "$MOCK_TOOLS/rogue-tool/adapter.sh"

    # Mock osv tool: run.sh writes a scan/v1 manifest for the osv token.
    # Copies a golden SARIF (findings/empty) per WRANGLE_EXTRA_RESULTS, with the
    # fixtures dir forwarded as WRANGLE_EXTRA_FIXTURES (run.sh strips env but
    # forwards WRANGLE_EXTRA_*); tool name/version come from the golden driver.
    mkdir -p "$MOCK_TOOLS/osv"
    cat > "$MOCK_TOOLS/osv/install.sh" << 'INST'
#!/bin/bash
set -euo pipefail
exit 0
INST
    chmod +x "$MOCK_TOOLS/osv/install.sh"

    cat > "$MOCK_TOOLS/osv/adapter.sh" << 'ADAPT'
#!/bin/bash
set -euo pipefail
if [[ "${RESULTS:-}" == "findings" ]]; then
    cp "${FIXTURES}/findings.sarif" "$2/output.sarif"
    exit 1
fi
cp "${FIXTURES}/empty.sarif" "$2/output.sarif"
exit 0
ADAPT
    chmod +x "$MOCK_TOOLS/osv/adapter.sh"

    # Mock wrangle-lint adapter: like osv, run.sh writes a scan/v1 manifest for
    # the wrangle-lint token. Its SARIF driver name is wrangle-lint.
    mkdir -p "$MOCK_TOOLS/wrangle-lint"
    cat > "$MOCK_TOOLS/wrangle-lint/adapter.sh" << 'ADAPT'
#!/bin/bash
set -euo pipefail
cat > "$2/output.sarif" << 'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"wrangle-lint","version":"1.2.3"}},"results":[]}]}
SARIF
exit 0
ADAPT
    chmod +x "$MOCK_TOOLS/wrangle-lint/adapter.sh"

    # Create test source and output directories
    mkdir -p "$TEST_DIR/src" "$TEST_DIR/output"
}

teardown() {
    cd "$ORIG_DIR" || exit 1
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

@test "orchestrator: rejects unknown tool (no directory)" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "nonexistent"

    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown tool"* ]]
}

@test "orchestrator: skips action-pattern tool (directory exists, no adapter.sh)" {
    # Create a tool directory with action.yml but no adapter.sh
    mkdir -p "$MOCK_TOOLS/action-tool"
    echo "name: test" > "$MOCK_TOOLS/action-tool/action.yml"

    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "action-tool"

    [ "$status" -eq 0 ]
}

@test "orchestrator: skips action-pattern tool even when an adapter.sh is present" {
    # A tool with an action.yml runs via its uses: step; an adapter.sh present
    # only as its image entrypoint must not pull it onto the in-process path.
    mkdir -p "$MOCK_TOOLS/action-img-tool"
    echo "name: test" > "$MOCK_TOOLS/action-img-tool/action.yml"
    cat > "$MOCK_TOOLS/action-img-tool/adapter.sh" << 'ADAPT'
#!/bin/bash
exit 2
ADAPT
    chmod +x "$MOCK_TOOLS/action-img-tool/adapter.sh"

    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "action-img-tool"

    [ "$status" -eq 0 ]
    [ ! -f "$TEST_DIR/output/action-img-tool/output.sarif" ]
}

@test "orchestrator: strips policy suffix from tool names" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool:fail"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/clean-tool/output.sarif" ]
}

@test "orchestrator: skips action-pattern tools in mixed list" {
    mkdir -p "$MOCK_TOOLS/action-tool"
    echo "name: test" > "$MOCK_TOOLS/action-tool/action.yml"

    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool" "action-tool:info"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/clean-tool/output.sarif" ]
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

@test "orchestrator: multiple tools land in distinct scan/<tool> dirs without clobbering" {
    # The build workflows fold this output into the unified metadata's scan/.
    # If a future change collapsed the per-tool subdir, the second tool would
    # overwrite the first's output.sarif and the merge would silently become a
    # clobber. Run two tools and assert both survive AND keep their own content.
    for t in osv zizmor; do
        mkdir -p "$MOCK_TOOLS/$t"
        printf '#!/bin/bash\nexit 0\n' > "$MOCK_TOOLS/$t/install.sh"
        chmod +x "$MOCK_TOOLS/$t/install.sh"
        cat > "$MOCK_TOOLS/$t/adapter.sh" << ADAPT
#!/bin/bash
set -euo pipefail
printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"$t"}},"results":[]}]}\n' > "\$2/output.sarif"
exit 0
ADAPT
        chmod +x "$MOCK_TOOLS/$t/adapter.sh"
    done

    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv" "zizmor"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/osv/output.sarif" ]
    [ -f "$TEST_DIR/output/zizmor/output.sarif" ]
    # Each subdir kept its own tool's SARIF — no cross-tool overwrite.
    grep -q '"name":"osv"' "$TEST_DIR/output/osv/output.sarif"
    grep -q '"name":"zizmor"' "$TEST_DIR/output/zizmor/output.sarif"
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

# --- Environment isolation tests ---

@test "orchestrator: strips GITHUB_TOKEN from adapter environment" {
    export GITHUB_TOKEN="secret-token-value"
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "env-check"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/env-check/env_dump.txt" ]
    # GITHUB_TOKEN must not be in the adapter's environment
    ! grep -q "GITHUB_TOKEN" "$TEST_DIR/output/env-check/env_dump.txt"
}

@test "orchestrator: forwards WRANGLE_EXTRA_ vars with prefix stripped" {
    export WRANGLE_EXTRA_MY_VAR="test-value"
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "env-check"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/env-check/env_dump.txt" ]
    # MY_VAR (without prefix) should be present
    grep -q "MY_VAR=test-value" "$TEST_DIR/output/env-check/env_dump.txt"
}

@test "orchestrator: detects filesystem modifications outside output_dir" {
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "rogue-tool"

    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"modified files"* ]]
}

@test "orchestrator: PATH is available to adapter" {
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "env-check"

    [ "$status" -eq 0 ]
    grep -q "^PATH=" "$TEST_DIR/output/env-check/env_dump.txt"
}

# --- Path resolution tests ---

@test "orchestrator: resolves tool paths relative to script, not cwd" {
    # Run from a different directory than the script
    cd "$TEST_DIR"
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool"

    [ "$status" -eq 0 ]
}

# --- Selective Go-tool install tests ---

# Build two mock adapters that each declare a distinct Go package in go-tools,
# plus a fake `go` that records the packages it was asked to install. Lets us
# assert run.sh builds only the requested adapter's package, never the others'.
setup_go_tools_mocks() {
    for t in gotool-a gotool-b; do
        mkdir -p "$MOCK_TOOLS/$t"
        printf '#!/bin/bash\nset -euo pipefail\nexit 0\n' > "$MOCK_TOOLS/$t/adapter.sh"
        chmod +x "$MOCK_TOOLS/$t/adapter.sh"
    done
    printf 'example.com/pkg/a\n' > "$MOCK_TOOLS/gotool-a/go-tools"
    printf 'example.com/pkg/b\n' > "$MOCK_TOOLS/gotool-b/go-tools"

    export GO_RECORD="$TEST_DIR/go-install-record"
    : > "$GO_RECORD"
    export FAKE_BIN="$TEST_DIR/fakebin"
    mkdir -p "$FAKE_BIN"

    # run.sh creates this to hold installed Go binaries (GOBIN). env.sh's
    # default is CWD-relative, which is unwritable under the read-only repo
    # mount the unit container runs in — point it at the writable test dir.
    export WRANGLE_BIN_DIR="$TEST_DIR/bin"
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
}

@test "orchestrator: installs only the Go package the requested adapter declares" {
    setup_go_tools_mocks

    PATH="$FAKE_BIN:$PATH" WRANGLE_TOOLS_DIR="$MOCK_TOOLS" \
        run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "gotool-a"

    [ "$status" -eq 0 ]
    grep -Fxq "example.com/pkg/a" "$GO_RECORD"
    ! grep -Fxq "example.com/pkg/b" "$GO_RECORD"
}

@test "orchestrator: skips the Go install entirely when no adapter declares a tool" {
    setup_go_tools_mocks

    # clean-tool has no go-tools file, so the fake go must never be invoked.
    PATH="$FAKE_BIN:$PATH" WRANGLE_TOOLS_DIR="$MOCK_TOOLS" \
        run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool"

    [ "$status" -eq 0 ]
    [ ! -s "$GO_RECORD" ]
}

# --- scan/v1 attestation manifest (issue #420) ---

@test "orchestrator: writes an osv scan/v1 manifest next to output.sarif (clean)" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv"
    [ "$status" -eq 0 ]
    manifest="$TEST_DIR/output/osv/wrangle_attestation_metadata.json"
    [ -f "$manifest" ]
    run jq -r '."predicate-type"' "$manifest"
    [[ "$output" == "https://github.com/TomHennen/wrangle/attestation/scan/v1" ]]
    run jq -r '.tool.name' "$manifest"
    [[ "$output" == "osv-scanner" ]]
    run jq -r '.tool.version' "$manifest"
    [[ "$output" == "1.0.0" ]]
    run jq -r '.result' "$manifest"
    [[ "$output" == "clean" ]]
    run jq -r '."result-file"' "$manifest"
    [[ "$output" == "output.sarif" ]]
}

@test "orchestrator: osv manifest records result=findings when osv reports findings" {
    WRANGLE_EXTRA_RESULTS=findings run_orchestrator \
        -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv"
    [ "$status" -eq 1 ]
    run jq -r '.result' "$TEST_DIR/output/osv/wrangle_attestation_metadata.json"
    [[ "$output" == "findings" ]]
}

@test "orchestrator: writes a wrangle-lint scan/v1 manifest next to output.sarif" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "wrangle-lint"
    [ "$status" -eq 0 ]
    manifest="$TEST_DIR/output/wrangle-lint/wrangle_attestation_metadata.json"
    [ -f "$manifest" ]
    run jq -r '.tool.name' "$manifest"
    [[ "$output" == "wrangle-lint" ]]
    run jq -r '.tool.version' "$manifest"
    [[ "$output" == "1.2.3" ]]
    run jq -r '.result' "$manifest"
    [[ "$output" == "clean" ]]
}

@test "orchestrator: writes no scan manifest for an unwired adapter" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_DIR/output/clean-tool/wrangle_attestation_metadata.json" ]
}

# --- image delivery: digest-pin enforcement (no docker; regex runs first) ---

# Drive run.sh's image-ref validation directly: the @sha256 check rejects a
# tag-only image before any docker call, and accepts a registry host:port pin.
_image_catalog() {
    # An image tool is "known" by its directory (no adapter.sh — the image is
    # the adapter); the catalog marks delivery: image.
    mkdir -p "$TEST_DIR/src" "$MOCK_TOOLS/imgtool"
    cat > "$MOCK_TOOLS/catalog.json" <<JSON
{"tools":{"imgtool":{"kind":"scan","delivery":"image","image":"$1"}}}
JSON
}

@test "orchestrator: image delivery rejects a tag-only (non-digest-pinned) image" {
    _image_catalog "registry.internal:5000/osv:latest"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "imgtool"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not digest-pinned"* ]]
}

@test "orchestrator: image delivery accepts a registry host:port digest pin" {
    digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    _image_catalog "registry.internal:5000/wrangle-osv@$digest"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "imgtool"
    # The pin passes validation, so the digest-pin error never fires; the run
    # then fails at docker (image absent / docker may be unavailable here).
    [[ "$output" != *"not digest-pinned"* ]]
}

# --- catalog-only image tool: admitted with no local tools/<name>/ dir ---

@test "orchestrator: a delivery: image tool with no directory is admitted (not unknown)" {
    digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    mkdir -p "$TEST_DIR/src"
    # No $MOCK_TOOLS/byotool directory; the catalog alone defines it.
    cat > "$MOCK_TOOLS/catalog.json" <<JSON
{"tools":{"byotool":{"kind":"sbom","delivery":"image","image":"registry.internal:5000/byo@$digest"}}}
JSON
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "byotool"
    # Reaches the image path rather than the "unknown tool" gate; docker then
    # fails (image absent / docker may be unavailable), which is not our concern.
    [[ "$output" != *"unknown tool"* ]]
    [[ "$output" == *"running byotool (image)"* ]]
}

@test "orchestrator: a tool with no directory and no catalog image entry is unknown" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "nodir"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown tool"* ]]
}

# --- custom-tools: path validation ---

@test "orchestrator: custom-tools path escaping the workspace is rejected" {
    mkdir -p "$TEST_DIR/ws"
    printf '{"tools":{}}' > "$TEST_DIR/outside.json"
    GITHUB_WORKSPACE="$TEST_DIR/ws" WRANGLE_CUSTOM_TOOLS="$TEST_DIR/outside.json" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool"
    [ "$status" -eq 2 ]
    [[ "$output" == *"escapes the workspace"* ]]
}

@test "orchestrator: a missing custom-tools file is rejected" {
    mkdir -p "$TEST_DIR/ws"
    GITHUB_WORKSPACE="$TEST_DIR/ws" WRANGLE_CUSTOM_TOOLS="$TEST_DIR/ws/nope.json" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "clean-tool"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not found"* ]]
}

@test "orchestrator: an in-workspace custom-tools file merges and admits a new tool" {
    digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    mkdir -p "$TEST_DIR/ws" "$TEST_DIR/src"
    cat > "$TEST_DIR/ws/tools.json" <<JSON
{"tools":{"byotool":{"kind":"sbom","delivery":"image","image":"registry.internal:5000/byo@$digest"}}}
JSON
    GITHUB_WORKSPACE="$TEST_DIR/ws" WRANGLE_CUSTOM_TOOLS="$TEST_DIR/ws/tools.json" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "byotool"
    [[ "$output" != *"unknown tool"* ]]
    [[ "$output" == *"running byotool (image)"* ]]
}

@test "orchestrator: a workspace-relative custom-tools path resolves (the composite seam)" {
    # The composites pass a workspace-relative path (.wrangle/tools.json) with cwd
    # = GITHUB_WORKSPACE; assert that resolves rather than being read as an escape.
    digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    mkdir -p "$TEST_DIR/ws/.wrangle" "$TEST_DIR/src"
    cat > "$TEST_DIR/ws/.wrangle/tools.json" <<JSON
{"tools":{"byotool":{"kind":"sbom","delivery":"image","image":"registry.internal:5000/byo@$digest"}}}
JSON
    cd "$TEST_DIR/ws"
    GITHUB_WORKSPACE="$TEST_DIR/ws" WRANGLE_CUSTOM_TOOLS=".wrangle/tools.json" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "byotool"
    [[ "$output" != *"escapes the workspace"* ]]
    [[ "$output" != *"not found"* ]]
    [[ "$output" == *"running byotool (image)"* ]]
}

@test "orchestrator: an invalid custom-tools entry aborts the run" {
    mkdir -p "$TEST_DIR/ws" "$TEST_DIR/src"
    cat > "$TEST_DIR/ws/tools.json" <<'JSON'
{"tools":{"byotool":{"kind":"sbom","delivery":"image","image":"ghcr.io/x:latest"}}}
JSON
    GITHUB_WORKSPACE="$TEST_DIR/ws" WRANGLE_CUSTOM_TOOLS="$TEST_DIR/ws/tools.json" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "byotool"
    [ "$status" -eq 2 ]
    [[ "$output" == *"digest-pinned"* ]]
}
