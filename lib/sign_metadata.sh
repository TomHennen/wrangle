#!/bin/bash
set -euo pipefail
set -f

_SIGN_METADATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "$_SIGN_METADATA_DIR/retry.sh"
# shellcheck source=lib/toolbox_run.sh
source "$_SIGN_METADATA_DIR/toolbox_run.sh"

# lib/sign_metadata.sh — Shared build-metadata signing primitives.
#
# Source this to sign the build metadata (SBOM + each scan/<tool>/ manifest
# wrangle-attest discovers under METADATA_ROOT), post each signed statement to
# the GitHub attestation store, and assemble one per-artifact
# <artifact>.intoto.jsonl bundle (provenance seed + that subject's signed
# metadata). The attest job signs + assembles; the verify job appends the VSA.
# Callers own the per-subject orchestration; these are the shared building blocks.
#
# Inputs (env): METADATA_ROOT (the metadata dir wrangle-attest reads), SUBJECTS
# (newline-separated dist file paths / sha256: digests, read by
# wrangle_read_subjects), GITHUB_REPOSITORY (store push target), GITHUB_TOKEN
# (bnd reads it to auth the store push), COMMIT (scanned git commit woven into
# the scan/v1 envelope). bnd keyless-signs via the caller's OIDC identity.

# Build the wrangle-attest arg vector (one arg per line for mapfile) that signs
# the build metadata into in-toto statements. $1 = subject arg
# (--subject=<digest> or --artifact=<file>); $2 = output JSONL path.
wrangle_attest_args() {
    printf '%s\n' \
        --metadata-root="$METADATA_ROOT" \
        "$1" \
        --commit="${COMMIT:-}" \
        --sign \
        --out="$2"
}

# Build the bnd arg vector that posts a signed statement to the GitHub
# attestation store. $1 is <owner>/<repo>; $2 the signed statement file. The
# store is keyed by subject digest, giving consumers by-digest discovery.
wrangle_bnd_push_args() {
    printf '%s\n' push github "$1" "$2"
}

# Sign subject $1's build-metadata statements (SBOM + scan/v1) into the JSONL at
# $2, one signed bundle per line; leaves $2 empty when there's no metadata. A
# digest-form subject (algo:hex) passes through as --subject; a file subject is
# self-digested by the engine via --artifact. Fails closed.
wrangle_sign_metadata_statements() {
    [[ -z "${METADATA_ROOT:-}" || ! -d "${METADATA_ROOT:-}" ]] && return 0
    local subject="$1" stmts="$2" subject_arg
    if [[ "$subject" =~ ^[a-z0-9]+:[a-f0-9]+$ ]]; then
        subject_arg="--subject=$subject"
    else
        subject_arg="--artifact=$subject"
    fi
    local args
    mapfile -t args < <(wrangle_attest_args "$subject_arg" "$stmts")
    if wrangle_toolbox_signing_enabled; then
        wrangle_mint_sigstore_token
        local -a m=()
        wrangle_toolbox_add_mount m "$METADATA_ROOT" ro
        wrangle_toolbox_add_mount m "$(dirname "$stmts")" rw
        [[ "$subject_arg" == --artifact=* ]] &&
            wrangle_toolbox_add_mount m "$(dirname "$subject")" ro
        wrangle_retry_once /dev/null wrangle_toolbox_exec \
            "${m[@]}" --env SIGSTORE_ID_TOKEN -- wrangle-attest "${args[@]}"
    else
        wrangle_retry_once /dev/null wrangle-attest "${args[@]}"
    fi
}

# Post the signed statement at $1 to the GitHub attestation store. Fails closed:
# a missing by-digest statement is a real delivery gap.
wrangle_push_store() {
    local args
    mapfile -t args < <(wrangle_bnd_push_args "$GITHUB_REPOSITORY" "$1")
    if wrangle_toolbox_signing_enabled; then
        local -a m=()
        wrangle_toolbox_add_mount m "$(dirname "$1")" ro
        wrangle_retry_once /dev/null wrangle_toolbox_exec \
            "${m[@]}" --env GITHUB_TOKEN -- bnd "${args[@]}"
    else
        wrangle_retry_once /dev/null bnd "${args[@]}"
    fi
}

# Build the cosign arg vector that pushes a single signed statement as an OCI
# referrer. `attach attestation` uploads verbatim (no re-sign), preserving the
# bnd signer; it accepts only one bundle line. $1 is the single-statement file,
# $2 the image digest ref.
wrangle_cosign_attach_args() {
    printf '%s\n' attach attestation \
        --attestation "$1" \
        "$2"
}

# Push the signed statement at $1 as its own OCI referrer on OCI_TARGET. No-op
# without OCI_TARGET (go/npm/python deliver via the store only). Fails closed:
# a missing by-digest referrer is a real delivery gap.
wrangle_push_oci_referrer() {
    [[ -z "${OCI_TARGET:-}" ]] && return 0
    local args
    mapfile -t args < <(wrangle_cosign_attach_args "$1" "$OCI_TARGET")
    if wrangle_toolbox_signing_enabled; then
        local -a m=()
        wrangle_toolbox_add_mount m "$(dirname "$1")" ro
        wrangle_retry_once /dev/null wrangle_toolbox_exec \
            "${m[@]}" --docker-config --env GITHUB_TOKEN -- cosign "${args[@]}"
    else
        wrangle_retry_once /dev/null cosign "${args[@]}"
    fi
}

# Build the cosign arg vector that downloads an image's attestation referrers as
# newline-delimited DSSE envelopes. $1 is the image digest ref.
wrangle_cosign_download_args() {
    printf '%s\n' download attestation "$1"
}

# The predicate the provenance seed filters to, so a re-run drops prior VSA
# referrers and rebuilds the same bundle (idempotent round-trip).
WRANGLE_PROVENANCE_PREDICATE="https://slsa.dev/provenance/v1"

# Write the shared provenance seed to $1: from the OCI referrer (container, when
# OCI_TARGET is set) or BUNDLE_IN (go/npm/python). Every per-artifact bundle
# copies this seed, so it runs once. Fails closed on a missing/malformed seed.
wrangle_seed_bundle() {
    local seed="$1"
    if [[ -n "${OCI_TARGET:-}" ]]; then
        local args downloaded
        mapfile -t args < <(wrangle_cosign_download_args "$OCI_TARGET")
        # Keep only the SLSA provenance envelopes (download emits all referrers,
        # including prior VSAs); a jq decode failure must fail, not seed empty.
        downloaded="$(mktemp "${RUNNER_TEMP:-/tmp}/seed.XXXXXX")"
        if wrangle_toolbox_signing_enabled; then
            wrangle_toolbox_exec --docker-config --env GITHUB_TOKEN -- cosign "${args[@]}" > "$downloaded"
        else
            cosign "${args[@]}" > "$downloaded"
        fi
        if ! jq -ce "select((.dsseEnvelope.payload | @base64d | fromjson | .predicateType) == \"$WRANGLE_PROVENANCE_PREDICATE\")" \
            "$downloaded" > "$seed"; then
            rm -f "$downloaded"
            printf 'wrangle: no SLSA provenance referrer found on %s (or malformed DSSE)\n' "$OCI_TARGET" >&2
            return 1
        fi
        rm -f "$downloaded"
    else
        [[ -s "$BUNDLE_IN" ]] || { printf 'wrangle: provenance seed %s missing or empty\n' "${BUNDLE_IN:-}" >&2; return 1; }
        cp "$BUNDLE_IN" "$seed"
    fi
}

# Map a subject (dist path or algo:hex digest) to its bundle filename: basename
# with the digest's colon replaced.
wrangle_bundle_name() {
    local base="${1##*/}"
    printf '%s.intoto.jsonl\n' "${base//:/-}"
}

# Sign every subject's build-metadata in the attest job and assemble one
# per-artifact <artifact>.intoto.jsonl bundle into BUNDLE_OUT: the shared
# provenance seed plus that subject's signed SBOM + scan/v1 lines. Each signed
# line is posted to the GitHub attestation store, and with OCI_TARGET set
# (container) additionally pushed as its own by-digest OCI referrer. Persisted
# independent of the policy verdict; the VSA stays in verify. Fails closed on a
# missing metadata dir, an unreadable provenance seed, a duplicate bundle
# basename, or a subject that yields no signed statement (the release SBOM is
# always present). Inputs (env): METADATA_ROOT, SUBJECTS, GITHUB_REPOSITORY,
# GITHUB_TOKEN, COMMIT, BUNDLE_OUT, one of BUNDLE_IN / OCI_TARGET (the seed
# source).
wrangle_sign_and_assemble_bundles() {
    if [[ -z "${METADATA_ROOT:-}" || ! -d "${METADATA_ROOT}" ]]; then
        printf 'wrangle: metadata dir %s missing — nothing to sign\n' "${METADATA_ROOT:-}" >&2
        return 1
    fi

    local -a WRANGLE_SUBJECTS
    wrangle_read_subjects

    mkdir -p "$BUNDLE_OUT"
    local seed
    seed="$(mktemp "${RUNNER_TEMP:-/tmp}/seed.XXXXXX")"
    wrangle_seed_bundle "$seed"

    local stmts subject line bundle
    stmts="$(mktemp "${RUNNER_TEMP:-/tmp}/attestmeta.XXXXXX")"
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        bundle="$BUNDLE_OUT/$(wrangle_bundle_name "$subject")"
        # Distinct subjects sharing a bundle basename would clobber each other.
        if [[ -e "$bundle" ]]; then
            printf 'wrangle: duplicate bundle basename %s — refusing to clobber\n' "${bundle##*/}" >&2
            rm -f "$stmts" "$seed"
            return 1
        fi
        : > "$stmts"
        wrangle_sign_metadata_statements "$subject" "$stmts"
        if [[ ! -s "$stmts" ]]; then
            printf 'wrangle: no signed metadata produced for %s\n' "$subject" >&2
            rm -f "$stmts" "$seed"
            return 1
        fi
        cp "$seed" "$bundle"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '%s\n' "$line" >> "$bundle"
            printf '%s\n' "$line" > "$stmts.line"
            wrangle_push_store "$stmts.line"
            wrangle_push_oci_referrer "$stmts.line"
        done < "$stmts"
        rm -f "$stmts.line"
    done
    rm -f "$stmts" "$seed"
}

# Split SUBJECTS into WRANGLE_SUBJECTS, dropping blank lines. Fail closed on an
# empty set: a release subject is always present, so zero means a wiring bug.
wrangle_read_subjects() {
    mapfile -t WRANGLE_SUBJECTS <<< "$SUBJECTS"
    local s kept=()
    for s in "${WRANGLE_SUBJECTS[@]}"; do
        [[ "$s" =~ ^[[:space:]]*$ ]] || kept+=("$s")
    done
    WRANGLE_SUBJECTS=("${kept[@]}")
    if [[ "${#WRANGLE_SUBJECTS[@]}" -eq 0 ]]; then
        printf 'wrangle: no subjects to sign — refusing to proceed\n' >&2
        return 1
    fi
}
