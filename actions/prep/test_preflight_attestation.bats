#!/usr/bin/env bats

# Tests for preflight_attestation.sh — prep's fail-closed refusal to attest a
# private repo. Two flavors:
#
#   - Behavioral: run the script with ATTESTATION / SHOULD_RELEASE / VISIBILITY
#     set, assert exit code + emitted message. These cover the refusal logic and
#     the input validation.
#   - Structural: fingerprints on prep's action.yml / the script that break if a
#     drive-by edit swaps the guard for a no-op, hands it a token, or strips the
#     env-passthrough pattern.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/preflight_attestation.sh"
    PREP="$BATS_TEST_DIRNAME/action.yml"
    GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
    : > "$GITHUB_OUTPUT"
    export GITHUB_OUTPUT
}

# --- behavioral: refusal ---

@test "behavior: required + private + release fails closed" {
    ATTESTATION=required SHOULD_RELEASE=true VISIBILITY=private run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"not supported on private repositories"* ]]
    [[ "$output" == *"attest-and-verify input to disabled"* ]]
    [[ "$output" == *"issues/600"* ]]
}

@test "behavior: internal is treated as non-public and fails closed" {
    # GitHub reports org-internal repos as `internal`; only `public` may attest.
    ATTESTATION=required SHOULD_RELEASE=true VISIBILITY=internal run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"not supported on private repositories"* ]]
}

@test "behavior: empty visibility is treated as non-public and fails closed" {
    # An event with no repository object yields an empty string; fail closed.
    ATTESTATION=required SHOULD_RELEASE=true VISIBILITY="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
}

# --- behavioral: pass ---

@test "behavior: required + public + release passes" {
    ATTESTATION=required SHOULD_RELEASE=true VISIBILITY=public run "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "behavior: disabled + private + release passes (unattested path)" {
    ATTESTATION=disabled SHOULD_RELEASE=true VISIBILITY=private run "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "behavior: required + private on a non-release run passes (no attestation attempted)" {
    ATTESTATION=required SHOULD_RELEASE=false VISIBILITY=private run "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

# --- behavioral: should-attest output ---

@test "should-attest: required + public + release writes true" {
    ATTESTATION=required SHOULD_RELEASE=true VISIBILITY=public run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -qx 'should-attest=true' "$GITHUB_OUTPUT"
}

@test "should-attest: disabled + release writes false" {
    ATTESTATION=disabled SHOULD_RELEASE=true VISIBILITY=public run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -qx 'should-attest=false' "$GITHUB_OUTPUT"
}

@test "should-attest: required + non-release writes false" {
    ATTESTATION=required SHOULD_RELEASE=false VISIBILITY=public run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -qx 'should-attest=false' "$GITHUB_OUTPUT"
}

@test "should-attest: required + private + release fails closed and never writes true" {
    ATTESTATION=required SHOULD_RELEASE=true VISIBILITY=private run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    ! grep -q 'should-attest=true' "$GITHUB_OUTPUT"
}

# --- behavioral: input validation ---

@test "behavior: an unknown attestation value fails loudly" {
    ATTESTATION=enabled SHOULD_RELEASE=true VISIBILITY=public run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"invalid attestation"* ]]
}

@test "behavior: an invalid value is rejected even on a non-release public run" {
    # Validation must not depend on the release/visibility branch being reached.
    ATTESTATION="disabled; rm -rf /" SHOULD_RELEASE=false VISIBILITY=public run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"invalid attestation"* ]]
}

# --- structural ---

@test "structure: script exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "structure: prep delegates to the script" {
    run grep -F 'preflight_attestation.sh' "$PREP"
    [[ "$status" -eq 0 ]]
}

@test "structure: prep reads visibility from the event context, not a token or API" {
    # The preflight MUST detect privacy from github.event only — prep holds no
    # permissions. A token/API read here would break that contract.
    run grep -F 'VISIBILITY: ${{ github.event.repository.visibility }}' "$PREP"
    [[ "$status" -eq 0 ]]
    run grep -F 'ATTESTATION: ${{ inputs.attest-and-verify }}' "$PREP"
    [[ "$status" -eq 0 ]]
}

@test "structure: prep stays permission-free and checkout-free" {
    run grep -F 'permissions: {}' "$BATS_TEST_DIRNAME/../../.github/workflows/build_and_publish_go.yml"
    [[ "$status" -eq 0 ]]
}

@test "structure: error message points adopters at the unattested mode and issue #600" {
    run grep -F 'attest-and-verify input to disabled' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    run grep -F 'issues/600' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}
