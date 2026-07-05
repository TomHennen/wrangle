#!/usr/bin/env bats

# Exercises the pull-time VSA gate (lib/verify_image_vsa.sh, #596) against REAL
# `gh attestation verify` and the REAL published, attested osv tool image — the
# load-bearing contract the unit suite can only shim. The happy path is
# dogfooded live; the negatives prove the identity, ref, and presence defenses
# actually reject, which a hand-authored gh shim cannot. Needs gh + auth +
# network (ghcr referrers + the Sigstore trust root), so it lives under
# test/image/ and skip_or_fails (never silently skips in CI) when unavailable.

# A real, public, digest-pinned image carrying no wrangle VSA. The gate must
# FAIL closed (no attestation found).
UNATTESTED_IMAGE="docker.io/library/registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"

setup_file() {
    load "../lib/bats_helpers"
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export ROOT
    # The catalog's pinned, attested osv digest, read live so a digest bump
    # can't leave this gate green-lighting a superseded image. The gate must
    # PASS against it.
    ATTESTED_OSV="$(jq -r '.tools.osv.image // empty' "$ROOT/tools/catalog.json")"
    export ATTESTED_OSV
    # The gate's own identity/issuer/predicate constants drive the negatives, so
    # a mutated copy is provably the only difference from the passing call.
    # shellcheck source=/dev/null
    source "$ROOT/lib/verify_image_vsa.sh"
}

setup() {
    load "../lib/bats_helpers"
    command -v gh >/dev/null 2>&1 || skip_or_fail "gh not installed"
    gh auth status >/dev/null 2>&1 || skip_or_fail "gh not authenticated"
    curl -fsS -m 15 -o /dev/null "https://ghcr.io/token?scope=repository:tomhennen/wrangle/osv:pull" \
        || skip_or_fail "ghcr.io unreachable"
    # shellcheck source=/dev/null
    source "$ROOT/lib/verify_image_vsa.sh"
}

# Run real `gh attestation verify` with the gate's constants but a caller-chosen
# identity regex and predicate type, so each negative isolates one defense.
_gh_verify() {
    local image="$1" identity_regex="$2" predicate="$3"
    timeout 120 gh attestation verify "oci://${image}" \
        --repo TomHennen/wrangle \
        --bundle-from-oci \
        --cert-identity-regex "$identity_regex" \
        --cert-oidc-issuer "$WRANGLE_VSA_OIDC_ISSUER" \
        --predicate-type "$predicate" \
        --format json
}

@test "real gh: gate PASSES against the pinned attested osv image" {
    run timeout 120 bash "$ROOT/lib/verify_image_vsa.sh" "$ATTESTED_OSV"
    [ "$status" -eq 0 ]
}

@test "real gh: gate PASSES against the catalog-pinned attest-toolbox image" {
    # Read the live pin so a stale toolbox digest fails here, not only at runtime.
    local image
    image="$(jq -r '.tools["attest-toolbox"].image // empty' "$ROOT/tools/catalog.json")"
    [ -n "$image" ]
    run timeout 120 bash "$ROOT/lib/verify_image_vsa.sh" "$image"
    [ "$status" -eq 0 ]
}

@test "real gh: gate FAILS closed against an unattested image" {
    run timeout 120 bash "$ROOT/lib/verify_image_vsa.sh" "$UNATTESTED_IMAGE"
    [ "$status" -eq 1 ]
}

@test "real gh: a non-wrangle signer identity is rejected (impersonation defense)" {
    run _gh_verify "$ATTESTED_OSV" \
        '^https://github\.com/evil/wrangle/' \
        "$WRANGLE_VSA_PREDICATE_TYPE"
    [ "$status" -ne 0 ]
}

@test "real gh: the gate's identity regex matches the real attestation's signer" {
    run _gh_verify "$ATTESTED_OSV" \
        "$WRANGLE_CONTAINER_SIGNER_REGEX" \
        "$WRANGLE_VSA_PREDICATE_TYPE"
    [ "$status" -eq 0 ]
}

@test "real gh: a tags-only ref regex rejects the main-built image (the main ref is load-bearing)" {
    # Tool images sign at @refs/heads/main; an identity regex that allowed only
    # release tags would reject every curated image. Proves the gate's regex
    # admitting refs/heads/main is deliberate, not lax.
    run _gh_verify "$ATTESTED_OSV" \
        '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_container\.yml@refs/tags/v[0-9.]+$' \
        "$WRANGLE_VSA_PREDICATE_TYPE"
    [ "$status" -ne 0 ]
}
