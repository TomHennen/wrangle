#!/usr/bin/env bats

# Structure guard for actions/verify's action.yml wiring.

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$DIR/action.yml"
    export DIR ACTION
}

@test "attach step is gated on both attach-to-release and attach-release-assets and threads the asset env" {
    grep -Fq "inputs.attach-to-release == 'true' && inputs.attach-release-assets == 'true'" "$ACTION"
    grep -Fq 'BUILD_TYPE: ${{ inputs.build-type }}' "$ACTION"
    grep -Fq 'DIST_DIR: ${{ inputs.dist-dir }}' "$ACTION"
    grep -Fq 'METADATA_ZIP_NAME: ${{ inputs.artifact-name }}.zip' "$ACTION"
    # No checkout in the verify job, so gh needs GH_REPO to resolve the release.
    grep -Fq 'GH_REPO: ${{ github.repository }}' "$ACTION"
}
