#!/usr/bin/env bats

# Tests for run.sh (orchestrator): the hermetic parse/selection seam and the
# path-independent post-run logic (0/1/2 exit mapping, scan/v1 manifest, error
# marker). run.sh dispatches every tool via its catalog image, so a mock `docker`
# on PATH stands in for the container — it derives the tool from the /output
# mount and replays a per-tool exit code + SARIF. Real image dispatch (sandbox,
# secret, network, uid ownership) is covered against a built image in
# test/image/test_run_image_dispatch.bats.

DIGEST="sha256:$(printf '0%.0s' {1..64})"

setup() {
    TEST_DIR="$(mktemp -d)"
    ORIG_DIR="$(pwd)"
    export TEST_DIR ORIG_DIR

    MOCK_TOOLS="$TEST_DIR/tools"
    BIN_DIR="$TEST_DIR/bin"
    MOCK_SPEC="$TEST_DIR/spec"
    mkdir -p "$MOCK_TOOLS" "$BIN_DIR" "$MOCK_SPEC" "$TEST_DIR/src" "$TEST_DIR/output"
    export MOCK_TOOLS MOCK_SPEC
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }

    # Curated-image VSA verification needs Sigstore; disabled for the mock images,
    # whose refs carry no real attestation.
    export WRANGLE_VERIFY_TOOL_IMAGES=0

    # Mock `docker`: on `docker run ... -v OUT:/output ... -- image /src /output`,
    # derive the tool from the /output mount, replay $MOCK_SPEC/<tool>.{sarif,exit}
    # (and .sleep, for the timeout test), and refuse if a host secret leaked onto
    # an -e flag — the container must never see GITHUB_TOKEN.
    cat > "$BIN_DIR/docker" <<'DOCKER'
#!/usr/bin/env bash
set -u
out="" ; prev=""
for a in "$@"; do
    [[ "$prev" == "-v" && "$a" == *:/output ]] && out="${a%:/output}"
    [[ "$a" == GITHUB_TOKEN* ]] && { printf 'mock docker: GITHUB_TOKEN reached the container\n' >&2; exit 97; }
    prev="$a"
done
[[ -n "$out" ]] || { printf 'mock docker: no /output mount\n' >&2; exit 96; }
tool="$(basename "$out")"
spec="$MOCK_SPEC/$tool"
[[ -f "$spec.sarif" ]] && cp "$spec.sarif" "$out/output.sarif"
[[ -f "$spec.sleep" ]] && sleep "$(cat "$spec.sleep")"
[[ -f "$spec.exit" ]] && exit "$(cat "$spec.exit")"
exit 0
DOCKER
    chmod +x "$BIN_DIR/docker"
    export PATH="$BIN_DIR:$PATH"
}

teardown() {
    cd "$ORIG_DIR" || exit 1
    rm -rf "$TEST_DIR"
}

# _image_tool <tool> [kind] — declare <tool> as a delivery: image tool in the
# mock catalog (kind: scan by default), digest-pinned on the curated namespace.
_image_tool() {
    local tool="$1" kind="${2:-scan}" cat="$MOCK_TOOLS/catalog.json" tmp
    [[ -f "$cat" ]] || printf '{"tools":{}}' > "$cat"
    tmp="$(mktemp)"
    jq --arg t "$tool" --arg k "$kind" --arg img "ghcr.io/tomhennen/wrangle/$tool@$DIGEST" \
        '.tools[$t] = {kind:$k, delivery:"image", image:$img}' "$cat" > "$tmp"
    mv "$tmp" "$cat"
}

# _spec <tool> <exit> [sarif-file] — set the mock image's replayed exit code and,
# optionally, the SARIF it writes into /output.
_spec() {
    printf '%s' "$2" > "$MOCK_SPEC/$1.exit"
    if [[ -n "${3:-}" ]]; then cp "$3" "$MOCK_SPEC/$1.sarif"; fi
}

run_orchestrator() {
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" "$@"
}

# --- Input validation / selection tests ---

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
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool"
    [ "$status" -eq 0 ]
}

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
}

@test "orchestrator: skips action-pattern tool even when an adapter.sh is present" {
    # A tool with an action.yml runs via its uses: step; an adapter.sh present
    # only as its image entrypoint must not pull it onto the run.sh dispatch path.
    mkdir -p "$MOCK_TOOLS/action-img-tool"
    echo "name: test" > "$MOCK_TOOLS/action-img-tool/action.yml"
    printf '#!/bin/bash\nexit 2\n' > "$MOCK_TOOLS/action-img-tool/adapter.sh"
    chmod +x "$MOCK_TOOLS/action-img-tool/adapter.sh"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "action-img-tool"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_DIR/output/action-img-tool/output.sarif" ]
}

@test "orchestrator: strips policy suffix from tool names" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool:fail"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/cleantool/output.sarif" ]
}

@test "orchestrator: skips action-pattern tools in a mixed list" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    mkdir -p "$MOCK_TOOLS/action-tool"
    echo "name: test" > "$MOCK_TOOLS/action-tool/action.yml"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool" "action-tool:info"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/cleantool/output.sarif" ]
}

@test "orchestrator: no tools provided prints usage" {
    run_orchestrator
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"usage"* ]]
}

# --- Execution: 0/1/2 exit mapping (mock docker) ---

@test "orchestrator: runs clean tool (exit 0)" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/cleantool/output.sarif" ]
}

@test "orchestrator: runs findings tool (exit 1)" {
    _image_tool findingstool
    _spec findingstool 1 "$ORIG_DIR/test/fixtures/findings.sarif"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "findingstool"
    [ "$status" -eq 1 ]
    [ -f "$TEST_DIR/output/findingstool/output.sarif" ]
}

@test "orchestrator: runs error tool (exit 2) and writes an error marker" {
    _image_tool errortool
    _spec errortool 2
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "errortool"
    [ "$status" -eq 2 ]
    # The marker lets check_results catch the failure even under continue-on-error
    # (and honor :info on the error).
    [ -f "$TEST_DIR/output/errortool/error" ]
}

@test "orchestrator: runs multiple tools" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    _image_tool findingstool
    _spec findingstool 1 "$ORIG_DIR/test/fixtures/findings.sarif"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool" "findingstool"
    [ "$status" -eq 1 ]
    [ -f "$TEST_DIR/output/cleantool/output.sarif" ]
    [ -f "$TEST_DIR/output/findingstool/output.sarif" ]
}

@test "orchestrator: multiple tools land in distinct scan/<tool> dirs without clobbering" {
    # The build workflows fold this output into the unified metadata's scan/. If a
    # future change collapsed the per-tool subdir, the second tool would overwrite
    # the first's output.sarif. Run two and assert both survive with their content.
    for t in osv zizmor; do
        _image_tool "$t"
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"%s"}},"results":[]}]}\n' "$t" \
            > "$MOCK_SPEC/$t.sarif"
        printf '0' > "$MOCK_SPEC/$t.exit"
    done
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv" "zizmor"
    [ "$status" -eq 0 ]
    grep -q '"name":"osv"' "$TEST_DIR/output/osv/output.sarif"
    grep -q '"name":"zizmor"' "$TEST_DIR/output/zizmor/output.sarif"
}

@test "orchestrator: error takes precedence over findings" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    _image_tool errortool
    _spec errortool 2
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool" "errortool"
    [ "$status" -eq 2 ]
}

@test "orchestrator: prints summary table" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool"
    [[ "$output" == *"cleantool"* ]]
}

@test "orchestrator: uses default src_dir and output_dir" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    cd "$TEST_DIR/src"
    mkdir -p metadata
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" "cleantool"
    [ "$status" -eq 0 ]
}

@test "orchestrator: image run timeout produces exit 2" {
    _image_tool slowtool
    _spec slowtool 0
    printf '30' > "$MOCK_SPEC/slowtool.sleep"
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" WRANGLE_ADAPTER_TIMEOUT=1 \
        run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "slowtool"
    [ "$status" -eq 2 ]
    [[ "$output" == *"timed out"* ]]
}

@test "orchestrator: GITHUB_TOKEN never reaches the container" {
    # docker gets only the -e flags run_tool_image builds; a host GITHUB_TOKEN
    # must not be among them. The mock docker exits 97 if it sees one.
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    export GITHUB_TOKEN="secret-token-value"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool"
    [ "$status" -eq 0 ]
}

# --- scan/v1 attestation manifest (issue #420), written in run.sh's shared
# post-run path regardless of how the tool ran ---

@test "orchestrator: writes an osv scan/v1 manifest next to output.sarif (clean)" {
    _image_tool osv
    _spec osv 0 "$ORIG_DIR/test/fixtures/empty.sarif"
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
    _image_tool osv
    _spec osv 1 "$ORIG_DIR/test/fixtures/findings.sarif"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "osv"
    [ "$status" -eq 1 ]
    run jq -r '.result' "$TEST_DIR/output/osv/wrangle_attestation_metadata.json"
    [[ "$output" == "findings" ]]
}

@test "orchestrator: writes a wrangle-lint scan/v1 manifest next to output.sarif" {
    _image_tool wrangle-lint
    printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"wrangle-lint","version":"1.2.3"}},"results":[]}]}\n' \
        > "$MOCK_SPEC/wrangle-lint.sarif"
    printf '0' > "$MOCK_SPEC/wrangle-lint.exit"
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

@test "orchestrator: writes no scan manifest for an unwired tool" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_DIR/output/cleantool/wrangle_attestation_metadata.json" ]
}

# --- Path resolution ---

@test "orchestrator: resolves tool paths relative to script, not cwd" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    cd "$TEST_DIR"
    WRANGLE_TOOLS_DIR="$MOCK_TOOLS" run "$ORIG_DIR/run.sh" -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool"
    [ "$status" -eq 0 ]
}

# --- image delivery: digest-pin enforcement (regex runs before any docker) ---

@test "orchestrator: image delivery rejects a tag-only (non-digest-pinned) image" {
    cat > "$MOCK_TOOLS/catalog.json" <<JSON
{"tools":{"imgtool":{"kind":"scan","delivery":"image","image":"registry.internal:5000/osv:latest"}}}
JSON
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "imgtool"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not digest-pinned"* ]]
}

@test "orchestrator: a delivery: image tool with no directory is admitted (not unknown)" {
    _image_tool byotool sbom
    _spec byotool 0
    run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "byotool"
    [[ "$output" != *"unknown tool"* ]]
    [[ "$output" == *"running byotool (image)"* ]]
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

# --- custom tools: auto-discovered .wrangle/tools.json at the workspace root ---

_byo_digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"

_write_custom_tools() {
    mkdir -p "$TEST_DIR/ws/.wrangle" "$TEST_DIR/src"
    printf '%s' "$1" > "$TEST_DIR/ws/.wrangle/tools.json"
}

@test "orchestrator: auto-discovers .wrangle/tools.json and admits a selected new tool" {
    _write_custom_tools "{\"tools\":{\"byotool\":{\"kind\":\"sbom\",\"delivery\":\"image\",\"image\":\"registry.internal:5000/byo@$_byo_digest\"}}}"
    _spec byotool 0
    GITHUB_WORKSPACE="$TEST_DIR/ws" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "byotool"
    [[ "$output" != *"unknown tool"* ]]
    [[ "$output" == *"running byotool (image)"* ]]
}

@test "orchestrator: no .wrangle/tools.json leaves the default catalog untouched" {
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    mkdir -p "$TEST_DIR/ws" "$TEST_DIR/src"
    GITHUB_WORKSPACE="$TEST_DIR/ws" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/output/cleantool/output.sarif" ]
}

@test "orchestrator: a .wrangle/tools.json symlink resolving outside the workspace is rejected" {
    mkdir -p "$TEST_DIR/ws/.wrangle" "$TEST_DIR/src"
    printf '{"tools":{}}' > "$TEST_DIR/outside.json"
    ln -s "$TEST_DIR/outside.json" "$TEST_DIR/ws/.wrangle/tools.json"
    GITHUB_WORKSPACE="$TEST_DIR/ws" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool"
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
    _image_tool cleantool
    _spec cleantool 0 "$ORIG_DIR/test/fixtures/empty.sarif"
    _write_custom_tools "{\"tools\":{\"injected\":{\"kind\":\"sbom\",\"delivery\":\"image\",\"image\":\"registry.internal:5000/evil@$_byo_digest\"}}}"
    GITHUB_WORKSPACE="$TEST_DIR/ws" \
        run_orchestrator -s "$TEST_DIR/src" -o "$TEST_DIR/output" "cleantool"
    [ "$status" -eq 0 ]
    [[ "$output" != *"injected"* ]]
    [ ! -d "$TEST_DIR/output/injected" ]
}
