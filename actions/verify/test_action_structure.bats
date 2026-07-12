#!/usr/bin/env bats

# Structure guard for actions/verify's action.yml wiring.

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$DIR/action.yml"
    export DIR ACTION
}

@test "verify signs + uploads only; it makes no release calls and needs no contents: write" {
    # Release upload moved to actions/publish_release; verify is verify+sign+
    # upload-bundle. It must hold no run_verify.sh attach call, no gh release
    # call, and no contents: write / GH token wiring.
    ! grep -Eq 'run_verify\.sh" attach' "$ACTION"
    ! grep -q 'gh release' "$ACTION"
    ! grep -q 'GH_REPO' "$ACTION"
    ! grep -q 'GH_TOKEN' "$ACTION"
    ! grep -qE '^[[:space:]]+contents: write' "$ACTION"
}
