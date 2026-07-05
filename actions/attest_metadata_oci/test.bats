#!/usr/bin/env bats

# Tests for actions/attest_metadata_oci/action.yml — the composite that signs the
# container build's SBOM + scan/v1 metadata in the attest job, pushes each line to
# the store AND as an OCI referrer, and assembles the per-artifact bundle (#550,
# #566). Structural assertions: the names computation, the metadata-pre download,
# the tool install, the sign step wiring, and the bundles artifact upload/output.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ACTION="$REPO_ROOT/actions/attest_metadata_oci/action.yml"
}

@test "attest_metadata_oci: computes the container names via lib/derive_names.sh" {
    run grep -F 'lib/derive_names.sh" container' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_metadata_oci: downloads the pre-verify metadata for signing" {
    run grep -F 'name: ${{ steps.names.outputs.metadata-pre }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_metadata_oci: signs the metadata" {
    run grep -F 'sign_metadata.sh' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_metadata_oci: signs over the image digest subject and pushes to the OCI target" {
    run grep -F 'SUBJECTS: ${{ inputs.subject-digest }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'OCI_TARGET: ${{ inputs.oci-target }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_metadata_oci: threads GITHUB_TOKEN and COMMIT into the sign step" {
    # bnd needs the token to auth the store push; COMMIT lands in the scan/v1 envelope.
    run grep -F 'GITHUB_TOKEN: ${{ github.token }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'COMMIT: ${{ github.sha }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_metadata_oci: uploads and outputs the bundles artifact" {
    run grep -F 'name: ${{ steps.names.outputs.bundles }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'value: ${{ steps.names.outputs.bundles }}' "$ACTION"
    [ "$status" -eq 0 ]
}

# The attest job runs no adopter-controlled code: it only downloads the already-
# built metadata and runs wrangle-attest/bnd/cosign over it. Guard against a
# future executable step that invokes a caller build/test hook.
@test "attest_metadata_oci: runs no adopter build/test hook (trust boundary)" {
    run grep -Ei '^[[:space:]]*(run:|- uses:|uses:).*(goreleaser|docker build|npm (run |test|ci)|python -m build|pytest|setup-script)' "$ACTION"
    [ "$status" -ne 0 ]
}
