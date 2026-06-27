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

# _vsa_err_is_transient — true if gh's stderr looks like a network/registry/
# Sigstore-availability blip (worth a retry), not a verification verdict. Erring
# toward "not transient" only fails faster; it can never pass a bad image,
# because a "verified" result still requires gh rc 0 AND vsa_assert_passed_l3,
# re-checked on every attempt against a deterministic attestation.
_vsa_err_is_transient() {
    printf '%s' "$1" | grep -qiE \
'connection refused|connection reset|dial tcp|no such host|i/o timeout|deadline exceeded|tls handshake|tuf refresh failed|failed to create tuf client|temporary failure|network is unreachable|server error|\b5[0-9][0-9]\b|timeout|: eof'
}

# verify_image_vsa <image> — verify a digest-pinned OCI image carries a PASSED,
# SLSA-L3 wrangle VSA signed by the container build+publish workflow at an
# allowed ref. The OCI referrer (--bundle-from-oci) is the canonical, fail-closed
# delivery. Transient failures (network/registry/Sigstore-TUF unreachable,
# timeout) are retried with backoff; a definitive verdict (non-PASSED VSA, no
# attestation, identity/ref mismatch) fails closed at once. Returns:
#   0  verified PASSED at SLSA Build L3
#   1  not provably PASSED (no / non-PASSED VSA, identity or ref mismatch, or a
#      transient failure that did not clear within the retry budget)
#   2  environment error (gh or jq not on PATH)
verify_image_vsa() {
    local image="$1"
    local timeout_s="${WRANGLE_VERIFY_TIMEOUT:-120}"
    local max_attempts="${WRANGLE_VERIFY_RETRIES:-3}"

    if ! command -v gh >/dev/null 2>&1; then
        printf 'wrangle: gh not found; cannot verify tool image attestation\n' >&2
        return 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        printf 'wrangle: jq not found; cannot verify tool image attestation\n' >&2
        return 2
    fi

    local attempt backoff=1 rc out err err_file
    err_file="$(mktemp)"
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        rc=0
        out="$(timeout "$timeout_s" gh attestation verify "oci://${image}" \
            --repo TomHennen/wrangle \
            --bundle-from-oci \
            --cert-identity-regex "$WRANGLE_CONTAINER_SIGNER_REGEX" \
            --cert-oidc-issuer "$WRANGLE_VSA_OIDC_ISSUER" \
            --predicate-type "$WRANGLE_VSA_PREDICATE_TYPE" \
            --format json 2>"$err_file")" || rc=$?

        if [[ "$rc" -eq 0 ]]; then
            # gh bound signature, identity, and subject digest; the verdict and
            # resourceUri (== this image ref) are ours.
            if printf '%s' "$out" | vsa_assert_passed_l3 "$image"; then
                rm -f "$err_file"
                return 0
            fi
            break  # gh verified but the VSA is not PASSED/L3: definitive.
        fi

        err="$(cat "$err_file")"
        # A timeout (124) is transient by nature; otherwise classify the stderr.
        if [[ "$attempt" -lt "$max_attempts" ]] \
            && { [[ "$rc" -eq 124 ]] || _vsa_err_is_transient "$err"; }; then
            printf 'wrangle: tool-image VSA verify attempt %d/%d failed (transient), retrying in %ds...\n' \
                "$attempt" "$max_attempts" "$backoff" >&2
            sleep "$backoff"
            backoff=$((backoff * 2))
            continue
        fi
        break  # definitive failure, or retries exhausted.
    done

    rm -f "$err_file"
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 1 ]]; then
        printf 'Usage: %s <image>\n' "${0##*/}" >&2
        exit 2
    fi
    verify_image_vsa "$1"
fi
