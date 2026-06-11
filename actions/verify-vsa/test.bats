#!/usr/bin/env bats

# Tests for the verify-vsa composite action. Three flavors:
#
#   - Behavioral: run verify_vsa.sh with an `ampel` shim on PATH that
#     records its argv. A shim is required because a real `ampel verify`
#     needs Sigstore (Fulcio/Rekor) plus a real keyless VSA for the exact
#     file digest — that lives in test/consumer/verify_consumer_vsa.bats
#     (real fixtures, real ampel) and the verify-vsa-action e2e job in
#     .github/workflows/test.yml. The resourceUri decode (jq over the DSSE
#     payload) runs for real against synthesized VSAs here.
#   - Structural: fingerprints on action.yml so a drive-by edit can't
#     silently drop the env passthrough, the pinned installer/download
#     steps, or the script delegation.
#   - Contract: divergence-fail guard tying this consumer to its producer
#     (the VSA artifact-name convention in actions/verify).

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    SCRIPT="$ACTION_DIR/verify_vsa.sh"
    POLICY="$ACTION_DIR/../../policies/wrangle-vsa-consumer-v1.hjson"
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

# Synthesize a DSSE bundle whose payload carries the given resourceUri — the
# script reads it for real with jq; verdict/identity logic runs against real
# VSAs in the e2e suites.
make_vsa() {
    local file_basename="$1" resource_uri="$2"
    local payload
    payload="$(jq -nc --arg r "$resource_uri" \
        '{predicate: {verificationResult: "PASSED", resourceUri: ($r == "" | if . then null else $r end)}}' | base64 -w0)"
    jq -nc --arg p "$payload" '{dsseEnvelope: {payload: $p}}' \
        > "$VSAS/$file_basename.intoto.jsonl"
}

# --- input validation ---

@test "behavior: fails without ARTIFACT_PATH" {
    ARTIFACT_PATH="" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"ARTIFACT_PATH is required"* ]]
}

@test "behavior: fails on nonexistent path" {
    ARTIFACT_PATH="$TMP/missing" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"no such file or directory"* ]]
}

@test "behavior: rejects malformed REPO" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="not-a-repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"REPO must be <owner>/<repo>"* ]]
}

@test "behavior: rejects missing VSA_DIR" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$TMP/nope" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"VSA_DIR is not a directory"* ]]
}

@test "behavior: fails when ampel is not on PATH" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz" "pkg:npm/a@1.0.0"
    # PATH pinned to system dirs only: the dev machine may carry a real ampel
    # somewhere on PATH, and env.sh re-adds only WRANGLE_BIN_DIR (empty here).
    PATH="/usr/bin:/bin" WRANGLE_BIN_DIR="$TMP/nobin" \
        ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" \
        run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"ampel not found"* ]]
}

@test "behavior: refuses an empty directory" {
    mkdir "$TMP/empty"
    ARTIFACT_PATH="$TMP/empty" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"refusing to pass an empty set"* ]]
}

@test "behavior: enumeration failure fails closed, not silent-subset" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a.tgz"
    make_vsa "a.tgz" "pkg:npm/a@1.0.0"
    # A find that emits some entries and then dies (unreadable subdir,
    # I/O error) must fail the run, not verify the readable subset.
    cat > "$TMP/bin/find" <<EOF
#!/usr/bin/env bash
printf 'partial\0'
exit 1
EOF
    chmod +x "$TMP/bin/find"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"failed to enumerate"* ]]
    [[ ! -f "$AMPEL_LOG" ]]
}

# --- verification dispatch ---

@test "behavior: file with no VSA fails closed before any ampel call" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no VSA found for"* ]]
    [[ ! -f "$AMPEL_LOG" ]]
}

@test "behavior: verifies via the consumer policy, binding subject, repo, and the VSA's resourceUri" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz" "pkg:npm/a@1.0.0"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 1 ]]
    grep -q -- "verify --subject $TMP/a.tgz" "$AMPEL_LOG"
    grep -q -- "--attestation $VSAS/a.tgz.intoto.jsonl" "$AMPEL_LOG"
    grep -q -- "--context sourceRepo:https://github.com/owner/repo" "$AMPEL_LOG"
    grep -q -- "--context expectedResourceUri:pkg:npm/a@1.0.0" "$AMPEL_LOG"
    grep -q -- "wrangle-vsa-consumer-v1.hjson" "$AMPEL_LOG"
    [[ "$output" == *"1 file(s) verified against PASSED VSAs"* ]]
}

@test "behavior: a bundle without a decodable payload fails with the decode error" {
    touch "$TMP/a.tgz"
    printf '{"notDsse":true}\n' > "$VSAS/a.tgz.intoto.jsonl"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"could not decode VSA payload"* ]]
    [[ ! -f "$AMPEL_LOG" ]]
}

@test "behavior: a VSA without a resourceUri fails before any ampel call" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz" ""
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"carries no resourceUri"* ]]
    [[ ! -f "$AMPEL_LOG" ]]
}

@test "behavior: fails closed when ampel rejects the VSA" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz" "pkg:npm/a@1.0.0"
    AMPEL_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" \
        run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

@test "behavior: verifies every file under a directory recursively, spaces included" {
    mkdir -p "$TMP/dist/nested"
    touch "$TMP/dist/a.whl" "$TMP/dist/b file.tar.gz" "$TMP/dist/nested/c.txt"
    make_vsa "a.whl" "pkg:generic/a@1"; make_vsa "b file.tar.gz" "pkg:generic/b@1"
    make_vsa "c.txt" "pkg:generic/c@1"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 3 ]]
    grep -q "b file.tar.gz" "$AMPEL_LOG"
    [[ "$output" == *"3 file(s) verified"* ]]
}

@test "behavior: stops at the first failing file" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a.tgz" "$TMP/dist/b.tgz"
    make_vsa "a.tgz" "pkg:npm/a@1"; make_vsa "b.tgz" "pkg:npm/b@1"
    AMPEL_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" \
        run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 1 ]]
}

# --- contract (divergence-fail guards across producer/consumer files) ---

@test "contract: producer uploads VSAs under the name this action resolves" {
    # actions/verify uploads one artifact per dist file, named
    # <artifact-name>.intoto.jsonl with artifact-name = the dist basename
    # (matrix.artifact in the build workflows); this action downloads
    # *.intoto.jsonl and resolves per file by basename. A producer-side
    # rename must fail here before it strands every adopter publish job.
    PRODUCER="$ACTION_DIR/../verify/action.yml"
    grep -q 'name: ${{ inputs.artifact-name }}.intoto.jsonl' "$PRODUCER"
    grep -q 'pattern: "\*.intoto.jsonl"' "$ACTION"
    grep -q '.intoto.jsonl' "$SCRIPT"
    WF_DIR="$ACTION_DIR/../../.github/workflows"
    grep -q 'artifact-name: ${{ matrix.artifact }}' "$WF_DIR/build_and_publish_npm.yml"
    grep -q 'artifact-name: ${{ matrix.artifact }}' "$WF_DIR/build_and_publish_python.yml"
}

# --- structural ---

@test "structure: action.yml threads inputs through env, not interpolation" {
    grep -q 'ARTIFACT_PATH: ${{ inputs.path }}' "$ACTION"
    grep -q 'REPO: ${{ inputs.repo }}' "$ACTION"
}

@test "structure: action.yml provisions Go, builds ampel from the tool manifest, and downloads VSAs via pinned steps" {
    grep -Eq 'uses: actions/setup-go@[0-9a-f]{40}' "$ACTION"
    grep -q 'go-version-file: ${{ github.action_path }}/../../tools/go.mod' "$ACTION"
    grep -q 'install github.com/carabiner-dev/ampel/cmd/ampel' "$ACTION"
    grep -Eq 'uses: actions/download-artifact@[0-9a-f]{40}' "$ACTION"
    grep -q 'pattern: "\*.intoto.jsonl"' "$ACTION"
}

@test "structure: action.yml delegates to verify_vsa.sh" {
    grep -q 'verify_vsa.sh' "$ACTION"
}

@test "structure: action.yml validates inputs before installing anything" {
    first_run="$(grep -o 'run: .*\.sh"' "$ACTION" | head -1)"
    [[ "$first_run" == *validate_inputs.sh* ]]
}
