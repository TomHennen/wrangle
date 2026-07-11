#!/usr/bin/env bats

# Tests for actions/verify_release/action.yml — the composite that owns the
# verify-job wiring the four reusable build workflows shared. Structural
# assertions: the staging downloads, the names/metadata-dir computation, and
# the actions/verify call live here so adding a verify input is one edit.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ACTION="$REPO_ROOT/actions/verify_release/action.yml"
}

@test "verify_release: computes names via lib/derive_names.sh" {
    run grep -F 'lib/derive_names.sh' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "verify_release: stages dist only when oci-target is empty" {
    # go/npm/python round-trip the dist through a workflow artifact; container
    # (oci-target set) has no workflow-artifact dist (the image is the artifact).
    run bash -c "grep -B2 'name: \${{ steps.names.outputs.dist }}' \"$ACTION\" | grep -F \"inputs.oci-target == ''\""
    [ "$status" -eq 0 ]
}

@test "verify_release: always downloads the attest-assembled bundles into the metadata dir" {
    run bash -c "grep -A1 'name: \${{ steps.names.outputs.bundles }}' \"$ACTION\" | grep -F 'path: \${{ steps.names.outputs.metadata-dir }}/'"
    [ "$status" -eq 0 ]
}

@test "verify_release: always stages the pre-verify metadata into the metadata dir" {
    run grep -F 'name: ${{ steps.names.outputs.metadata-pre }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'path: ${{ steps.names.outputs.metadata-dir }}/' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "verify_release: calls actions/verify with computed metadata-dir + metadata name" {
    run grep -F 'TomHennen/wrangle/actions/verify@' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'bundle-out: ${{ steps.names.outputs.metadata-dir }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'artifact-name: ${{ steps.names.outputs.metadata }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "verify_release: bundle-in points at the metadata dir for every build type" {
    run grep -F 'bundle-in: ${{ steps.names.outputs.metadata-dir }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "verify_release: no longer threads any release-attach inputs to verify (publish owns the upload)" {
    # Release upload moved to actions/publish_release; verify_release runs
    # verify+sign only, so it must pass no attach-* / dist-dir / metadata-dir /
    # build-type wiring to the verify action.
    ! grep -qF 'attach-to-release:' "$ACTION"
    ! grep -qF 'attach-release-assets:' "$ACTION"
    ! grep -qF 'dist-dir:' "$ACTION"
    ! grep -qF 'metadata-dir: ${{ steps.names.outputs.metadata-dir }}' "$ACTION"
}
