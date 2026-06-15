#!/usr/bin/env bats

# Tests for the verify-vsa composite action. Three flavors:
#
#   - Behavioral: run verify_vsa.sh with an `ampel` shim on PATH that
#     records its argv. A shim is required because a real `ampel verify`
#     needs Sigstore (Fulcio/Rekor) plus a real keyless VSA for the exact
#     file digest — that lives in test/consumer/verify_consumer_vsa.bats
#     (real fixtures, real ampel) and the verify-vsa-action e2e job in
#     .github/workflows/test.yml.
#   - Structural: fingerprints on action.yml so a drive-by edit can't
#     silently drop the env passthrough, the pinned installer/download
#     steps, or the script delegation.
#   - Contract: divergence-fail guard tying this consumer to its producer
#     (the bundle artifact-name convention in actions/verify).

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    SCRIPT="$ACTION_DIR/verify_vsa.sh"
    TMP="$(mktemp -d)"
    AMPEL_LOG="$TMP/ampel_calls.log"
    VSAS="$TMP/vsas"
    mkdir -p "$VSAS"

    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/ampel" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$AMPEL_LOG"
exit "\${AMPEL_SHIM_EXIT:-0}"
EOF
    chmod +x "$TMP/bin/ampel"
    PATH="$TMP/bin:$PATH"
}

teardown() { rm -rf "$TMP"; }

# The bundle only has to exist for the dispatch tests — the shim never reads
# it; verdict/identity/resourceUri logic runs against real VSAs in the e2e
# suites. One bundle per build, namespaced subdir (the download-artifact
# no-merge layout).
make_bundle() {
    local sub="${1:-go-bundle-_}"
    mkdir -p "$VSAS/$sub"
    printf '{"dsseEnvelope":{"payload":""}}\n' > "$VSAS/$sub/multiple.intoto.jsonl"
}

# --- input validation ---

@test "behavior: fails without ARTIFACT_PATH" {
    ARTIFACT_PATH="" RESOURCE_URI="pkg:npm/a@1" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"ARTIFACT_PATH is required"* ]]
}

@test "behavior: fails on nonexistent path" {
    ARTIFACT_PATH="$TMP/missing" RESOURCE_URI="pkg:npm/a@1" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"no such file or directory"* ]]
}

@test "behavior: fails without RESOURCE_URI" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" RESOURCE_URI="" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"RESOURCE_URI is required"* ]]
}

@test "behavior: rejects malformed REPO" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" RESOURCE_URI="pkg:npm/a@1" REPO="not-a-repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"REPO must be <owner>/<repo>"* ]]
}

@test "behavior: rejects a RESOURCE_URI carrying an injected context pair (fail-closed)" {
    touch "$TMP/a.tgz"
    make_bundle
    # A comma would let a second --context pair ride in and override the
    # sourceRepo binding; reject before any ampel call.
    ARTIFACT_PATH="$TMP/a.tgz" VSA_DIR="$VSAS" REPO="owner/repo" \
        RESOURCE_URI="pkg:npm/a@1,sourceRepo:https://github.com/attacker/evil" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"RESOURCE_URI has disallowed characters"* ]]
    [[ ! -f "$AMPEL_LOG" ]]
}

@test "behavior: rejects missing VSA_DIR" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" RESOURCE_URI="pkg:npm/a@1" REPO="owner/repo" VSA_DIR="$TMP/nope" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"VSA_DIR is not a directory"* ]]
}

@test "behavior: fails when ampel is not on PATH" {
    touch "$TMP/a.tgz"
    make_bundle
    # PATH pinned to system dirs only: the dev machine may carry a real ampel
    # somewhere on PATH, and env.sh re-adds only WRANGLE_BIN_DIR (empty here).
    PATH="/usr/bin:/bin" WRANGLE_BIN_DIR="$TMP/nobin" \
        ARTIFACT_PATH="$TMP/a.tgz" RESOURCE_URI="pkg:npm/a@1" REPO="owner/repo" VSA_DIR="$VSAS" \
        run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"ampel not found"* ]]
}

@test "behavior: refuses an empty directory" {
    mkdir "$TMP/empty"
    make_bundle
    ARTIFACT_PATH="$TMP/empty" RESOURCE_URI="pkg:npm/a@1" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"refusing to pass an empty set"* ]]
}

@test "behavior: fails closed when no bundle was downloaded" {
    # An empty VSA_DIR means the bundle download produced nothing; refuse to
    # publish rather than verify against an empty attestation set.
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" RESOURCE_URI="pkg:npm/a@1" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"no VSA bundle found"* ]]
    [[ ! -f "$AMPEL_LOG" ]]
}

@test "behavior: enumeration failure fails closed, not silent-subset" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a.tgz"
    make_bundle
    # A find that emits some entries and then dies (unreadable subdir,
    # I/O error) must fail the run, not verify the readable subset.
    cat > "$TMP/bin/find" <<EOF
#!/usr/bin/env bash
printf 'partial\0'
exit 1
EOF
    chmod +x "$TMP/bin/find"
    ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="pkg:npm/a@1" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"failed to enumerate"* ]]
    [[ ! -f "$AMPEL_LOG" ]]
}

# --- verification dispatch ---

@test "behavior: verifies via the consumer policy, binding subject, repo, and resource URI" {
    touch "$TMP/a.tgz"
    make_bundle
    ARTIFACT_PATH="$TMP/a.tgz" RESOURCE_URI="pkg:npm/a@1.0.0" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 1 ]]
    grep -q -- "verify --subject $TMP/a.tgz" "$AMPEL_LOG"
    # The whole bundle is passed as one --attestation; ampel self-selects the VSA.
    grep -q -- "--attestation " "$AMPEL_LOG"
    grep -q -- "--context sourceRepo:https://github.com/owner/repo" "$AMPEL_LOG"
    grep -q -- "--context expectedResourceUri:pkg:npm/a@1.0.0" "$AMPEL_LOG"
    grep -q -- "wrangle-vsa-consumer-v1.hjson" "$AMPEL_LOG"
    [[ "$output" == *"1 file(s) verified against PASSED VSAs"* ]]
}

# WRANGLE_VSA_NON_STRICT=1 is wrangle's own dogfood switch: it selects the
# ref-relaxed consumer policy. Hermetic here (shim records the --policy path);
# the real admit/reject behavior is exercised in test/consumer with real ampel.
@test "behavior: WRANGLE_VSA_NON_STRICT=1 selects the non-strict consumer policy" {
    touch "$TMP/a.tgz"
    make_bundle
    WRANGLE_VSA_NON_STRICT=1 \
        ARTIFACT_PATH="$TMP/a.tgz" RESOURCE_URI="pkg:npm/a@1.0.0" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -q -- "wrangle-vsa-consumer-nonstrict-v1.hjson" "$AMPEL_LOG"
}

@test "behavior: fails closed when ampel rejects the VSA" {
    touch "$TMP/a.tgz"
    make_bundle
    AMPEL_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/a.tgz" RESOURCE_URI="pkg:npm/a@1" REPO="owner/repo" VSA_DIR="$VSAS" \
        run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

@test "behavior: concatenates every per-build bundle so any subject resolves" {
    # A multi-build run downloads several namespaced bundles; verify_vsa.sh
    # combines them into one JSONL ampel reads. Two builds, two files — both
    # verify against the combined bundle.
    touch "$TMP/a.tgz" "$TMP/b.whl"
    make_bundle "go-bundle-_"
    make_bundle "python-bundle-pkg"
    mkdir "$TMP/dist"; mv "$TMP/a.tgz" "$TMP/b.whl" "$TMP/dist/"
    ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="pkg:generic/a@1" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 2 ]]
    [[ "$output" == *"2 file(s) verified"* ]]
}

@test "behavior: verifies every file under a directory recursively, spaces included" {
    mkdir -p "$TMP/dist/nested"
    touch "$TMP/dist/a.whl" "$TMP/dist/b file.tar.gz" "$TMP/dist/nested/c.txt"
    make_bundle
    ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="pkg:generic/a@1" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 3 ]]
    grep -q "b file.tar.gz" "$AMPEL_LOG"
    [[ "$output" == *"3 file(s) verified"* ]]
}

@test "behavior: stops at the first failing file" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a.tgz" "$TMP/dist/b.tgz"
    make_bundle
    AMPEL_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="pkg:npm/a@1" REPO="owner/repo" VSA_DIR="$VSAS" \
        run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 1 ]]
}

# --- contract (divergence-fail guards across producer/consumer files) ---

@test "contract: producer uploads the bundle under the name this action resolves" {
    # actions/verify uploads one bundle artifact per build, named
    # <type>-bundle-<shortname>; this action downloads *-bundle-* and
    # concatenates every multiple.intoto.jsonl found. A producer-side rename
    # must fail here before it strands every adopter publish job.
    PRODUCER="$ACTION_DIR/../verify/action.yml"
    grep -q 'name: ${{ inputs.artifact-name }}' "$PRODUCER"
    grep -q 'pattern: "\*-bundle-\*"' "$ACTION"
    grep -q '.intoto.jsonl' "$SCRIPT"
    WF_DIR="$ACTION_DIR/../../.github/workflows"
    grep -q 'artifact-name: npm-bundle-' "$WF_DIR/build_and_publish_npm.yml"
    grep -q 'artifact-name: python-bundle-' "$WF_DIR/build_and_publish_python.yml"
}

@test "contract: the build workflows export the resource-uri this action expects" {
    # The README and examples pipe the workflow's resource-uri output into
    # this action's resource-uri input; a renamed or dropped output strands
    # every adopter publish job.
    # Match the workflow_call output specifically (its value references the
    # build job's output), not the job-level composition line that shares the
    # `resource-uri:` key — deleting the adopter-facing export must fail here.
    WF_DIR="$ACTION_DIR/../../.github/workflows"
    grep -q 'value: ${{ jobs.build.outputs.resource-uri }}' "$WF_DIR/build_and_publish_npm.yml"
    grep -q 'value: ${{ jobs.build.outputs.resource-uri }}' "$WF_DIR/build_and_publish_python.yml"
}

# --- structural ---

@test "structure: action.yml threads inputs through env, not interpolation" {
    grep -q 'ARTIFACT_PATH: ${{ inputs.path }}' "$ACTION"
    grep -q 'RESOURCE_URI: ${{ inputs.resource-uri }}' "$ACTION"
    grep -q 'REPO: ${{ inputs.repo }}' "$ACTION"
}

@test "structure: action.yml provisions Go, builds ampel from the tool manifest, and downloads the bundle via pinned steps" {
    grep -Eq 'uses: actions/setup-go@[0-9a-f]{40}' "$ACTION"
    grep -q 'go-version-file: ${{ github.action_path }}/../../tools/go.mod' "$ACTION"
    grep -q 'install github.com/carabiner-dev/ampel/cmd/ampel' "$ACTION"
    grep -Eq 'uses: actions/download-artifact@[0-9a-f]{40}' "$ACTION"
    grep -q 'pattern: "\*-bundle-\*"' "$ACTION"
}

@test "structure: action.yml delegates to verify_vsa.sh" {
    grep -q 'verify_vsa.sh' "$ACTION"
}

@test "structure: action.yml validates inputs before installing anything" {
    first_run="$(grep -o 'run: .*\.sh"' "$ACTION" | head -1)"
    [[ "$first_run" == *validate_inputs.sh* ]]
}
