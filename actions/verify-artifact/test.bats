#!/usr/bin/env bats

# Tests for the verify-artifact composite action. Three flavors:
#
#   - Behavioral: run verify_artifact.sh with a `cosign` shim on PATH that
#     records its argv. A shim is required for the signature step: a real
#     `cosign verify-blob-attestation` needs Sigstore (Fulcio/Rekor) plus a
#     real keyless VSA for the exact file digest — that lives in
#     test/consumer/verify_consumer_vsa.bats, which runs this script
#     end-to-end against the real fixtures with real cosign. The
#     predicate-decode gate (jq over the DSSE payload) runs for real
#     against synthesized VSAs here.
#   - Structural: fingerprints on action.yml so a drive-by edit can't
#     silently drop the env passthrough, the pinned installer/download
#     steps, or the script delegation.
#   - Contract: divergence-fail guards tying this consumer to its
#     producers (the VSA artifact-name convention in actions/verify and
#     the signer identity in the consumer PolicySet).

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    SCRIPT="$ACTION_DIR/verify_artifact.sh"
    TMP="$(mktemp -d)"
    COSIGN_LOG="$TMP/cosign_calls.log"
    VSAS="$TMP/vsas"
    mkdir -p "$VSAS"

    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/cosign" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$COSIGN_LOG"
exit "\${COSIGN_SHIM_EXIT:-0}"
EOF
    chmod +x "$TMP/bin/cosign"
    PATH="$TMP/bin:$PATH"
}

teardown() { rm -rf "$TMP"; }

# Synthesize a DSSE bundle whose payload carries the given verificationResult.
make_vsa() {
    local file_basename="$1" result="$2"
    local payload
    payload="$(jq -nc --arg r "$result" '{predicate: {verificationResult: $r}}' | base64 -w0)"
    jq -nc --arg p "$payload" '{dsseEnvelope: {payload: $p}}' \
        > "$VSAS/$file_basename.intoto.jsonl"
}

# --- input validation ---

@test "behavior: fails without ARTIFACT_PATH" {
    ARTIFACT_PATH="" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"ARTIFACT_PATH is required"* ]]
}

@test "behavior: fails on nonexistent path" {
    ARTIFACT_PATH="$TMP/missing" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"no such file or directory"* ]]
}

@test "behavior: rejects malformed REPO" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="not-a-repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"REPO must be <owner>/<repo>"* ]]
}

@test "behavior: rejects missing VSA_DIR" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$TMP/nope" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"VSA_DIR is not a directory"* ]]
}

@test "behavior: rejects malformed SIGNER_WORKFLOW" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" \
        SIGNER_WORKFLOW='owner/repo/wf.yml; rm -rf /' run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"SIGNER_WORKFLOW must be"* ]]
}

@test "behavior: refuses an empty directory" {
    mkdir "$TMP/empty"
    ARTIFACT_PATH="$TMP/empty" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"refusing to pass an empty set"* ]]
}

@test "behavior: enumeration failure fails closed, not silent-subset" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a.tgz"
    make_vsa "a.tgz" "PASSED"
    # A find that emits some entries and then dies (unreadable subdir,
    # I/O error) must fail the run, not verify the readable subset.
    cat > "$TMP/bin/find" <<EOF
#!/usr/bin/env bash
printf 'partial\0'
exit 1
EOF
    chmod +x "$TMP/bin/find"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"failed to enumerate"* ]]
    [[ ! -f "$COSIGN_LOG" ]]
}

# --- verification dispatch ---

@test "behavior: file with no VSA fails closed before any cosign call" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no VSA found for"* ]]
    [[ ! -f "$COSIGN_LOG" ]]
}

@test "behavior: verifies a PASSED VSA, binding repo, type, and signer regex" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz" "PASSED"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$COSIGN_LOG")" -eq 1 ]]
    grep -q -- "verify-blob-attestation --bundle $VSAS/a.tgz.intoto.jsonl --new-bundle-format" "$COSIGN_LOG"
    grep -q -- "--certificate-github-workflow-repository owner/repo" "$COSIGN_LOG"
    grep -q -- "--type https://slsa.dev/verification_summary/v1" "$COSIGN_LOG"
    grep -q -- "build_and_publish_" "$COSIGN_LOG"
    [[ "$output" == *"1 file(s) verified against PASSED VSAs"* ]]
}

@test "behavior: SIGNER_WORKFLOW becomes an anchored identity regex" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz" "PASSED"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" \
        SIGNER_WORKFLOW="TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml" \
        run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -q -- '--certificate-identity-regexp ^https://github\\.com/TomHennen/wrangle/\\.github/workflows/build_and_publish_npm\\.yml@' "$COSIGN_LOG"
}

@test "behavior: a non-PASSED verdict fails even when cosign accepts the signature" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz" "FAILED"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"does not say PASSED"* ]]
}

@test "behavior: a bundle without a decodable payload fails with the decode error" {
    touch "$TMP/a.tgz"
    printf '{"notDsse":true}\n' > "$VSAS/a.tgz.intoto.jsonl"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"could not decode VSA payload"* ]]
}

@test "behavior: fails closed when cosign rejects the VSA" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz" "PASSED"
    COSIGN_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" \
        SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"cosign rejected"* ]]
}

@test "behavior: verifies every file under a directory recursively, spaces included" {
    mkdir -p "$TMP/dist/nested"
    touch "$TMP/dist/a.whl" "$TMP/dist/b file.tar.gz" "$TMP/dist/nested/c.txt"
    make_vsa "a.whl" "PASSED"; make_vsa "b file.tar.gz" "PASSED"; make_vsa "c.txt" "PASSED"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$COSIGN_LOG")" -eq 3 ]]
    grep -q "b file.tar.gz" "$COSIGN_LOG"
    [[ "$output" == *"3 file(s) verified"* ]]
}

@test "behavior: stops at the first failing file" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a.tgz" "$TMP/dist/b.tgz"
    make_vsa "a.tgz" "PASSED"; make_vsa "b.tgz" "PASSED"
    COSIGN_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" \
        SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$(wc -l < "$COSIGN_LOG")" -eq 1 ]]
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

@test "contract: default signer regex stays equivalent to the consumer policy identity" {
    POLICY="$ACTION_DIR/../../policies/wrangle-vsa-consumer-v1.hjson"
    policy_re="$(grep -o 'identity: "[^"]*"' "$POLICY" | sed -e 's/identity: "//' -e 's/"$//')"
    policy_re="${policy_re//\\\\/\\}"      # hjson escaping: \\ -> \
    policy_re="${policy_re%.+\$}"          # the script omits the trailing .+$
    script_re="$(grep -o "WRANGLE_SIGNER_REGEX='[^']*'" "$SCRIPT" | sed -e "s/WRANGLE_SIGNER_REGEX='//" -e "s/'\$//")"
    [[ -n "$policy_re" ]] && [[ -n "$script_re" ]]
    [[ "$script_re" == "$policy_re" ]]
}

# --- structural ---

@test "structure: action.yml threads inputs through env, not interpolation" {
    grep -q 'ARTIFACT_PATH: ${{ inputs.path }}' "$ACTION"
    grep -q 'SIGNER_WORKFLOW: ${{ inputs.signer-workflow }}' "$ACTION"
    grep -q 'REPO: ${{ inputs.repo }}' "$ACTION"
}

@test "structure: action.yml installs cosign and downloads VSAs via pinned actions" {
    grep -Eq 'uses: sigstore/cosign-installer@[0-9a-f]{40}' "$ACTION"
    grep -Eq 'uses: actions/download-artifact@[0-9a-f]{40}' "$ACTION"
    grep -q 'pattern: "\*.intoto.jsonl"' "$ACTION"
}

@test "structure: action.yml delegates to verify_artifact.sh" {
    grep -q 'verify_artifact.sh' "$ACTION"
}
