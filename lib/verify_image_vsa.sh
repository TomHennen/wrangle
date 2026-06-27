#!/bin/bash
# lib/verify_image_vsa.sh — Pull-time VSA verification primitive for wrangle
# tool images. Sourced by run.sh; also runnable directly for a one-off check.
#
# Provides:
#   vsa_assert_passed_l3  — read `gh attestation verify --format json` on stdin
#                           and assert a non-empty array of PASSED, SLSA-L3 VSAs
#   verify_image_vsa      — run the gate against an OCI image (0/1/2 contract)

set -euo pipefail
set -f

# The reusable workflow that SIGNS wrangle's tool images, matched against the
# attestation cert's subject alternative name. gh's --signer-workflow pins
# repo+workflow but not the ref; this regex also pins the ref, allowing only a
# main build (curated images build from main) or a release tag.
WRANGLE_CONTAINER_SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_container\.yml@refs/(heads/main|tags/v[0-9.]+)$'
WRANGLE_VSA_OIDC_ISSUER='https://token.actions.githubusercontent.com'
WRANGLE_VSA_PREDICATE_TYPE='https://slsa.dev/verification_summary/v1'

# vsa_assert_passed_l3 — read a `gh attestation verify --format json` array on
# stdin; succeed only if it is non-empty AND every entry is a PASSED VSA verified
# at SLSA Build L3. gh checks signature, identity, and digest but NEVER the
# predicate verdict, so this is the ONLY check that the verdict is PASSED;
# dropping it makes the gate theater. Array-safe — an empty array fails.
vsa_assert_passed_l3() {
    jq -e '
        length > 0 and all(.[];
            .verificationResult.statement.predicate.verificationResult == "PASSED"
            and any(.verificationResult.statement.predicate.verifiedLevels[];
                    . == "SLSA_BUILD_LEVEL_3"))' >/dev/null
}

# verify_image_vsa <image> — verify a digest-pinned OCI image carries a PASSED,
# SLSA-L3 wrangle VSA signed by the container build+publish workflow at an
# allowed ref. The OCI referrer (--bundle-from-oci) is the canonical, fail-closed
# delivery. Returns:
#   0  verified PASSED at SLSA Build L3
#   1  not provably PASSED (no / non-PASSED VSA, identity or ref mismatch, gh
#      runtime or network failure, timeout)
#   2  environment error (gh or jq not on PATH)
verify_image_vsa() {
    local image="$1"
    local timeout_s="${WRANGLE_VERIFY_TIMEOUT:-120}"

    if ! command -v gh >/dev/null 2>&1; then
        printf 'wrangle: gh not found; cannot verify tool image attestation\n' >&2
        return 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        printf 'wrangle: jq not found; cannot verify tool image attestation\n' >&2
        return 2
    fi

    local rc=0
    timeout "$timeout_s" gh attestation verify "oci://${image}" \
        --repo TomHennen/wrangle \
        --bundle-from-oci \
        --cert-identity-regex "$WRANGLE_CONTAINER_SIGNER_REGEX" \
        --cert-oidc-issuer "$WRANGLE_VSA_OIDC_ISSUER" \
        --predicate-type "$WRANGLE_VSA_PREDICATE_TYPE" \
        --format json \
        | vsa_assert_passed_l3 \
        || rc=$?
    # Any failure past the env pre-checks is "not provably PASSED": refuse.
    [[ "$rc" -eq 0 ]] || return 1
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 1 ]]; then
        printf 'Usage: %s <image>\n' "${0##*/}" >&2
        exit 2
    fi
    verify_image_vsa "$1"
fi
