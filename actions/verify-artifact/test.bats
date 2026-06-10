#!/usr/bin/env bats

# Tests for the verify-artifact composite action. Two flavors:
#
#   - Behavioral: run verify_artifact.sh with a `cosign` shim on PATH that
#     records its argv. A shim is required for the signature step: a real
#     `cosign verify-blob-attestation` needs Sigstore (Fulcio/Rekor) plus a
#     real keyless VSA for the exact file digest — that is the
#     test/consumer integration suite's job. The predicate-decode gate
#     (jq over the DSSE payload) runs for real against synthesized VSAs.
#   - Structural: fingerprints on action.yml so a drive-by edit can't
#     silently drop the env passthrough, the pinned installer/download
#     steps, or the script delegation.

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

@test "behavior: fails on nonexistent path" {
    ARTIFACT_PATH="$TMP/missing" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"no such file or directory"* ]]
}

@test "behavior: refuses an empty directory" {
    mkdir "$TMP/empty"
    ARTIFACT_PATH="$TMP/empty" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"refusing to pass an empty set"* ]]
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

@test "behavior: fails closed when cosign rejects the VSA" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz" "PASSED"
    COSIGN_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" \
        SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"cosign rejected"* ]]
}

@test "behavior: verifies every file under a directory, recursively" {
    mkdir -p "$TMP/dist/nested"
    touch "$TMP/dist/a.whl" "$TMP/dist/b.tar.gz" "$TMP/dist/nested/c.txt"
    make_vsa "a.whl" "PASSED"; make_vsa "b.tar.gz" "PASSED"; make_vsa "c.txt" "PASSED"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$COSIGN_LOG")" -eq 3 ]]
    [[ "$output" == *"3 file(s) verified"* ]]
}

@test "behavior: handles filenames with spaces" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a file.tgz"
    make_vsa "a file.tgz" "PASSED"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -q "a file.tgz" "$COSIGN_LOG"
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

# --- structural ---

@test "structure: action.yml threads inputs through env, not interpolation" {
    grep -q 'ARTIFACT_PATH: ${{ inputs.path }}' "$ACTION"
    grep -q 'SIGNER_WORKFLOW: ${{ inputs.signer-workflow }}' "$ACTION"
    grep -q 'REPO: ${{ inputs.repo }}' "$ACTION"
    ! grep -E '\$\{\{ inputs\.' "$ACTION" | grep -q 'run:'
}

@test "structure: action.yml installs cosign and downloads VSAs via pinned actions" {
    grep -Eq 'uses: sigstore/cosign-installer@[0-9a-f]{40}' "$ACTION"
    grep -Eq 'uses: actions/download-artifact@[0-9a-f]{40}' "$ACTION"
    grep -q 'pattern: "\*.intoto.jsonl"' "$ACTION"
}

@test "structure: action.yml delegates to verify_artifact.sh" {
    grep -q 'verify_artifact.sh' "$ACTION"
}
