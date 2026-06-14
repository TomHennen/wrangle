#!/usr/bin/env bats

# Drift guard: the wrangle VSA signer-identity ref-anchor lives in two places
# that MUST agree — the consumer PolicySet (policies/wrangle-vsa-consumer-v1.hjson)
# that ampel enforces, and the cosign `--certificate-identity-regexp` in
# docs/verifying_artifacts.md that the guide tells consumers to run. Loosen one
# (e.g. back to `@.+`, or to a bare SHA) without the other and a consumer
# following the docs checks a weaker identity than the policy actually requires.
# This fails closed on divergence. See DEP_MGMT.md § Drift.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    POLICY="$REPO_ROOT/policies/wrangle-vsa-consumer-v1.hjson"
    GUIDE="$REPO_ROOT/docs/verifying_artifacts.md"
}

@test "wrangle VSA identity anchor is the release tag in both the policy and the cosign guide" {
    # Both must anchor the wrangle VSA signer identity on a release tag.
    grep -q 'yml@refs/tags/v' "$POLICY"
    grep -q 'yml@refs/tags/v' "$GUIDE"
}

@test "no loosened wrangle VSA identity anchor (@.+ or a bare SHA) remains" {
    # A `build_and_publish_<type>.yml@` anchor that is `@.+` or a 40-hex SHA
    # would admit a non-release wrangle invocation — the gap this PR closes.
    # Both files in ONE grep so the negation is the governing command: under
    # bats' set -e a non-final `! grep` is not allowed to fail the test.
    ! grep -qE 'yml@(\.\+|[0-9a-f]{40})' "$POLICY" "$GUIDE"
}
