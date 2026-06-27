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

_VERIFY_IMAGE_VSA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "$_VERIFY_IMAGE_VSA_DIR/retry.sh"

# The reusable workflow that SIGNS wrangle's tool images, matched against the
# attestation cert's subject alternative name. gh's --signer-workflow pins
# repo+workflow but not the ref; this regex also pins the ref, allowing only a
# main build (curated images build from main) or a release tag.
WRANGLE_CONTAINER_SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_container\.yml@refs/(heads/main|tags/v[0-9.]+)$'
WRANGLE_VSA_OIDC_ISSUER='https://token.actions.githubusercontent.com'
WRANGLE_VSA_PREDICATE_TYPE='https://slsa.dev/verification_summary/v1'

# vsa_assert_passed_l3 <expected_resource_uri> — read a `gh attestation verify
# --format json` array on stdin; succeed only if it is non-empty AND every entry
# is a PASSED VSA, verified at SLSA Build L3, whose resourceUri equals the
# expected image ref. gh checks signature, identity, and the subject digest but
# NEVER the predicate verdict or resourceUri, so this is the ONLY check of those;
# resourceUri-binding is the SLSA VSA spec's producer-intent check and matches
# policies/wrangle-vsa-consumer-v1.hjson. Array-safe — an empty array fails.
vsa_assert_passed_l3() {
    local expected_uri="$1"
    jq -e --arg uri "$expected_uri" '
        length > 0 and all(.[];
            .verificationResult.statement.predicate.verificationResult == "PASSED"
            and .verificationResult.statement.predicate.resourceUri == $uri
            and any(.verificationResult.statement.predicate.verifiedLevels[];
                    . == "SLSA_BUILD_LEVEL_3"))' >/dev/null
}

# verify_image_vsa <image> — verify a digest-pinned OCI image carries a PASSED,
# SLSA-L3 wrangle VSA signed by the container build+publish workflow at an
# allowed ref. The OCI referrer (--bundle-from-oci) is the canonical, fail-closed
# delivery. A transient gh failure (network/registry/Sigstore-TUF unreachable) is
# retried once via wrangle_retry_once; the deterministic verdict check then runs
# on the surviving attempt's output, so a non-PASSED VSA is never retried into a
# pass. Returns:
#   0  verified PASSED at SLSA Build L3
#   1  not provably PASSED (no / non-PASSED VSA, identity or ref mismatch, or a
#      failure that did not clear on the retry)
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

    local json rc=0
    json="$(mktemp)"
    wrangle_retry_once "$json" timeout "$timeout_s" gh attestation verify "oci://${image}" \
        --repo TomHennen/wrangle \
        --bundle-from-oci \
        --cert-identity-regex "$WRANGLE_CONTAINER_SIGNER_REGEX" \
        --cert-oidc-issuer "$WRANGLE_VSA_OIDC_ISSUER" \
        --predicate-type "$WRANGLE_VSA_PREDICATE_TYPE" \
        --format json || rc=$?

    # gh bound signature, identity, and subject digest; the verdict and
    # resourceUri (== this image ref) are ours, checked once (never retried).
    if [[ "$rc" -eq 0 ]] && vsa_assert_passed_l3 "$image" < "$json"; then
        rm -f "$json"
        return 0
    fi
    rm -f "$json"
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 1 ]]; then
        printf 'Usage: %s <image>\n' "${0##*/}" >&2
        exit 2
    fi
    verify_image_vsa "$1"
fi
