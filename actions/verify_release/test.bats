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

@test "verify_release: stages dist + provenance only when oci-target is empty" {
    # go/npm/python round-trip both through workflow artifacts; container
    # (oci-target set) seeds them from the registry referrer instead.
    run bash -c "grep -B2 'name: \${{ steps.names.outputs.dist }}' \"$ACTION\" | grep -F \"inputs.oci-target == ''\""
    [ "$status" -eq 0 ]
    run bash -c "grep -B2 'name: \${{ steps.names.outputs.provenance-bundle }}' \"$ACTION\" | grep -F \"inputs.oci-target == ''\""
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

@test "verify_release: bundle-in is set for jsonl builds and empty for container" {
    run grep -F "inputs.oci-target == '' && 'provenance/provenance.jsonl'" "$ACTION"
    [ "$status" -eq 0 ]
}

@test "verify_release: threads build-type and attach-release-assets to the release attach" {
    run grep -F 'attach-release-assets: ${{ inputs.attach-release-assets }}' "$ACTION"
    [ "$status" -eq 0 ]
    # build-type drives the go-vs-others dist distinction in the attach step.
    run grep -F 'build-type: ${{ inputs.build-type }}' "$ACTION"
    [ "$status" -eq 0 ]
}
