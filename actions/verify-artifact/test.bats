#!/usr/bin/env bats

# Tests for the verify-artifact composite action. Two flavors:
#
#   - Behavioral: run verify_artifact.sh with a `gh` shim on PATH that
#     records its argv. A shim is required here: a real `gh attestation
#     verify` needs network plus a real attestation in GitHub's store for
#     the exact file digest, so the real call is integration/e2e surface
#     (the showcase publish jobs exercise it); these tests cover input
#     validation, file discovery, and the argv contract instead.
#   - Structural: fingerprints on action.yml so a drive-by edit can't
#     silently drop the env passthrough or the script delegation.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    SCRIPT="$ACTION_DIR/verify_artifact.sh"
    TMP="$(mktemp -d)"
    GH_LOG="$TMP/gh_calls.log"

    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
exit "\${GH_SHIM_EXIT:-0}"
EOF
    chmod +x "$TMP/bin/gh"
    PATH="$TMP/bin:$PATH"
}

teardown() { rm -rf "$TMP"; }

# --- input validation ---

@test "behavior: fails without ARTIFACT_PATH" {
    ARTIFACT_PATH="" REPO="owner/repo" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"ARTIFACT_PATH is required"* ]]
}

@test "behavior: rejects malformed REPO" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="not-a-repo" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"REPO must be <owner>/<repo>"* ]]
}

@test "behavior: rejects malformed SIGNER_WORKFLOW" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" \
        SIGNER_WORKFLOW='owner/repo/wf.yml; rm -rf /' run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"SIGNER_WORKFLOW must be"* ]]
}

@test "behavior: fails on nonexistent path" {
    ARTIFACT_PATH="$TMP/missing" REPO="owner/repo" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"no such file or directory"* ]]
}

@test "behavior: refuses an empty directory" {
    mkdir "$TMP/empty"
    ARTIFACT_PATH="$TMP/empty" REPO="owner/repo" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"refusing to pass an empty set"* ]]
}

# --- verification dispatch ---

@test "behavior: verifies a single file with --signer-workflow" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" \
        SIGNER_WORKFLOW="TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml" \
        run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$GH_LOG")" -eq 1 ]]
    grep -q -- "attestation verify $TMP/a.tgz --repo owner/repo --signer-workflow TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml" "$GH_LOG"
    [[ "$output" == *"1 file(s) verified"* ]]
}

@test "behavior: verifies every file under a directory, recursively" {
    mkdir -p "$TMP/dist/nested"
    touch "$TMP/dist/a.whl" "$TMP/dist/b.tar.gz" "$TMP/dist/nested/c.txt"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$GH_LOG")" -eq 3 ]]
    [[ "$output" == *"3 file(s) verified"* ]]
}

@test "behavior: handles filenames with spaces" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a file.tgz"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -q "a file.tgz" "$GH_LOG"
}

@test "behavior: empty SIGNER_WORKFLOW falls back to the wrangle signer regex" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -q -- "--cert-identity-regex" "$GH_LOG"
    grep -q "build_and_publish_" "$GH_LOG"
}

@test "behavior: fails closed when gh verification fails" {
    touch "$TMP/a.tgz"
    GH_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" \
        SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -ne 0 ]]
}

@test "behavior: stops at the first failing file" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a.tgz" "$TMP/dist/b.tgz"
    GH_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" \
        SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -ne 0 ]]
    [[ "$(wc -l < "$GH_LOG")" -eq 1 ]]
}

# --- structural ---

@test "structure: action.yml threads inputs through env, not interpolation" {
    grep -q 'ARTIFACT_PATH: ${{ inputs.path }}' "$ACTION"
    grep -q 'SIGNER_WORKFLOW: ${{ inputs.signer-workflow }}' "$ACTION"
    grep -q 'GH_TOKEN: ${{ inputs.github-token }}' "$ACTION"
    ! grep -E '\$\{\{ inputs\.' "$ACTION" | grep -q 'run:'
}

@test "structure: action.yml delegates to verify_artifact.sh" {
    grep -q 'verify_artifact.sh' "$ACTION"
}
