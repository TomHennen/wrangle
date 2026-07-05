#!/usr/bin/env bats

# Unit tests for run.sh (orchestrator): the docker-independent parse/selection
# seam — tool-name validation, action-pattern skip, unknown-tool rejection,
# digest-pin enforcement, and custom-tool (.wrangle/tools.json) discovery. These
# assert what run.sh decides BEFORE it dispatches an image, so they need no
# container. Actual image execution (0/1/2 mapping, manifest, error marker,
# secret/network/uid) is covered against a real image in
# test/image/test_run_image_dispatch.bats.

setup() {
    TEST_DIR="$(mktemp -d)"
    ORIG_DIR="$(pwd)"
    export TEST_DIR ORIG_DIR
    MOCK_TOOLS="$TEST_DIR/tools"
    mkdir -p "$MOCK_TOOLS" "$TEST_DIR/src" "$TEST_DIR/output"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }
    # No real image is dispatched here, so the VSA gate (which needs Sigstore) is
    # off; each test asserts the decision run.sh prints before `docker run`.
    export WRANGLE_VERIFY_TOOL_IMAGES=0
}

teardown() {
    cd "$ORIG_DIR" || exit 1
    rm -rf "$TEST_DIR"
}

# _image_tool <tool> [kind] — declare <tool> as a delivery: image tool in the
# mock catalog, digest-pinned on the curated namespace.
_image_tool() {
    local tool="$1" kind="${2:-scan}" cat="$MOCK_TOOLS/catalog.json" tmp digest
    digest="sha256:$(printf '0%.0s' {1..64})"
    [[ -f "$cat" ]] || printf '{"tools":{}}' > "$cat"
    tmp="$(mktemp)"
    jq --arg t "$tool" --arg k "$kind" --arg img "ghcr.io/tomhennen/wrangle/$tool@$digest" \
        '.tools[$t] = {kind:$k, delivery:"image", image:$img}' "$cat" > "$tmp"
    mv "$tmp" "$cat"
}

run_orchestrator() {
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" "$@"
}

# --- Tool-name validation ---

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

@test "orchestrator: no tools provided prints usage" {
    run_orchestrator
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"usage"* ]]
}

# --- Selection: unknown-tool rejection & action-pattern skip ---

@test "orchestrator: rejects unknown tool (no directory, no catalog entry)" {
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "nonexistent"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown tool"* ]]
}

@test "orchestrator: skips action-pattern tool (directory exists, no adapter.sh)" {
    mkdir -p "$MOCK_TOOLS/action-tool"
    echo "name: test" > "$MOCK_TOOLS/action-tool/action.yml"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "action-tool"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no tools to run"* ]]
}

@test "orchestrator: skips action-pattern tool even when an adapter.sh is present" {
    # A tool with an action.yml runs via its uses: step; an adapter.sh present
    # only as its image entrypoint must not pull it onto the dispatch path.
    mkdir -p "$MOCK_TOOLS/action-img-tool"
    echo "name: test" > "$MOCK_TOOLS/action-img-tool/action.yml"
    printf '#!/bin/bash\nexit 2\n' > "$MOCK_TOOLS/action-img-tool/adapter.sh"
    chmod +x "$MOCK_TOOLS/action-img-tool/adapter.sh"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "action-img-tool"
    [ "$status" -eq 0 ]
    [ ! -d "$TEST_DIR/output/action-img-tool" ]
}

@test "orchestrator: skips the action-pattern tool in a mixed list, dispatches the image tool" {
    _image_tool osv
    mkdir -p "$MOCK_TOOLS/action-tool"
    echo "name: test" > "$MOCK_TOOLS/action-tool/action.yml"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv" "action-tool:info"
    # osv reaches image dispatch; action-tool is skipped (no dir, never dispatched).
    [[ "$output" == *"running osv (image)"* ]]
    [ ! -d "$TEST_DIR/output/action-tool" ]
}

@test "orchestrator: strips the :policy suffix before resolving the tool" {
    _image_tool osv
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv:info"
    # The suffix is stripped, so osv (not "osv:info") resolves to the image path.
    [[ "$output" == *"running osv (image)"* ]]
    [[ "$output" != *"invalid tool name"* ]]
}

# --- Digest-pin enforcement (regex runs before any docker) ---

@test "orchestrator: image delivery rejects a tag-only (non-digest-pinned) image" {
    cat > "$MOCK_TOOLS/catalog.json" <<JSON
{"tools":{"imgtool":{"kind":"scan","delivery":"image","image":"registry.internal:5000/osv:latest"}}}
JSON
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "imgtool"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not digest-pinned"* ]]
    # A config failure writes the error marker too, so an :info tool with a bad
    # pin still blocks the check (check_results reads the marker).
    [ -f "$TEST_DIR/output/imgtool/error" ]
}

@test "orchestrator: a delivery: image tool with no directory is admitted (not unknown)" {
    _image_tool byotool sbom
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "byotool"
    [[ "$output" != *"unknown tool"* ]]
    [[ "$output" == *"running byotool (image)"* ]]
}

@test "orchestrator: resolves its libs and tools relative to the script, not cwd" {
    # run.sh sources lib/*.sh and finds the catalog via SCRIPT_DIR; invoked from an
    # unrelated cwd it must still resolve osv to the image path (not fail to load).
    _image_tool osv
    cd "$TEST_DIR"
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv"
    [[ "$output" == *"running osv (image)"* ]]
}

@test "orchestrator: the curated sbom key dispatches as a catalog-only image tool" {
    # The default SBOM path (sbom-tool: sbom) has no tools/sbom/ dir, so it relies
    # on the parse loop resolving the real catalog's sbom entry to the image path.
    [ ! -d "$ORIG_DIR/tools/sbom" ]
    WRANGLE_TOOLS_DIR="$ORIG_DIR/tools" \
        run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" sbom
    [[ "$output" != *"unknown tool"* ]]
    [[ "$output" == *"running sbom (image)"* ]]
}

# --- Custom tools: auto-discovered .wrangle/tools.json at the workspace root ---

_byo_digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"

_write_custom_tools() {
    mkdir -p "$TEST_DIR/ws/.wrangle" "$TEST_DIR/src"
    printf '%s' "$1" > "$TEST_DIR/ws/.wrangle/tools.json"
}

@test "orchestrator: auto-discovers .wrangle/tools.json and admits a selected new tool" {
    _write_custom_tools "{\"tools\":{\"byotool\":{\"kind\":\"sbom\",\"delivery\":\"image\",\"image\":\"registry.internal:5000/byo@$_byo_digest\"}}}"
    GITHUB_WORKSPACE="$TEST_DIR/ws" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "byotool"
    [[ "$output" != *"unknown tool"* ]]
    [[ "$output" == *"running byotool (image)"* ]]
}

@test "orchestrator: no .wrangle/tools.json leaves the default catalog untouched" {
    _image_tool osv
    mkdir -p "$TEST_DIR/ws" "$TEST_DIR/src"
    GITHUB_WORKSPACE="$TEST_DIR/ws" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv"
    # osv resolves from the curated catalog, unaffected by the absent custom file.
    [[ "$output" == *"running osv (image)"* ]]
}

@test "orchestrator: a .wrangle/tools.json symlink resolving outside the workspace is rejected" {
    mkdir -p "$TEST_DIR/ws/.wrangle" "$TEST_DIR/src"
    printf '{"tools":{}}' > "$TEST_DIR/outside.json"
    ln -s "$TEST_DIR/outside.json" "$TEST_DIR/ws/.wrangle/tools.json"
    GITHUB_WORKSPACE="$TEST_DIR/ws" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv"
    [ "$status" -eq 2 ]
    [[ "$output" == *"resolves outside the workspace"* ]]
}

@test "orchestrator: an invalid .wrangle/tools.json entry aborts the run" {
    _write_custom_tools '{"tools":{"byotool":{"kind":"sbom","delivery":"image","image":"ghcr.io/x:latest"}}}'
    GITHUB_WORKSPACE="$TEST_DIR/ws" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "byotool"
    [ "$status" -eq 2 ]
    [[ "$output" == *"digest-pinned"* ]]
}

@test "orchestrator: a custom tool defined but NOT selected is never dispatched" {
    # Selection gates execution: an injected .wrangle/tools.json entry the
    # selection does not name stays defined-but-never-run (the property that makes
    # auto-discovery safe under pull_request_target).
    _image_tool osv
    _write_custom_tools "{\"tools\":{\"injected\":{\"kind\":\"sbom\",\"delivery\":\"image\",\"image\":\"registry.internal:5000/evil@$_byo_digest\"}}}"
    GITHUB_WORKSPACE="$TEST_DIR/ws" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv"
    [[ "$output" != *"injected"* ]]
    [ ! -d "$TEST_DIR/output/injected" ]
}
