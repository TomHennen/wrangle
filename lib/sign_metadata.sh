#!/bin/bash
set -euo pipefail
set -f

# lib/sign_metadata.sh — Shared build-metadata signing primitives.
#
# Source this to sign the build metadata (SBOM + each scan/<tool>/ manifest
# wrangle-attest discovers under METADATA_ROOT) and post each signed statement
# to the GitHub attestation store. Used by both the verify job (alongside the
# VSA) and the attest job (independent of the policy verdict). Callers own the
# per-subject orchestration; these are the shared building blocks.
#
# Inputs (env): METADATA_ROOT (the metadata dir wrangle-attest reads), SUBJECTS
# (newline-separated dist file paths / sha256: digests, read by
# wrangle_read_subjects), GITHUB_REPOSITORY (store push target), GITHUB_TOKEN
# (bnd reads it to auth the store push), COMMIT (scanned git commit woven into
# the scan/v1 envelope). bnd keyless-signs via the caller's OIDC identity.

# Run a command, retrying once on failure to absorb transient Sigstore I/O.
# Re-evaluation is deterministic, so a retry can only flip a transient failure.
# $1 is the stdout capture, truncated per attempt. WRANGLE_RETRY_DELAY spaces
# the attempts (tests set it to 0).
wrangle_retry_once() {
    local out="$1"; shift
    "$@" > "$out" && return 0
    local rc=$?
    printf 'wrangle: %s failed (exit %s); retrying once for transient Sigstore I/O\n' "$1" "$rc" >&2
    sleep "${WRANGLE_RETRY_DELAY:-5}"
    "$@" > "$out"
}

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
    wrangle_retry_once /dev/null wrangle-attest "${args[@]}"
}

# Post the signed statement at $1 to the GitHub attestation store. Fails closed:
# a missing by-digest statement is a real delivery gap.
wrangle_push_store() {
    local args
    mapfile -t args < <(wrangle_bnd_push_args "$GITHUB_REPOSITORY" "$1")
    wrangle_retry_once /dev/null bnd "${args[@]}"
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
    wrangle_retry_once /dev/null cosign "${args[@]}"
}

# Sign and push every subject's build-metadata in the attest job, accumulating
# each signed line into OUT (the emitted signed-metadata artifact). Each line is
# posted to the GitHub attestation store, and with OCI_TARGET set (container)
# additionally pushed as its own by-digest OCI referrer. Persisted independent of
# the policy verdict; the VSA stays in verify. Fails closed on a missing metadata
# dir or a subject that yields no signed statement (the release SBOM is always
# present). Inputs (env): METADATA_ROOT, SUBJECTS, GITHUB_REPOSITORY,
# GITHUB_TOKEN, COMMIT, OUT, optional OCI_TARGET.
wrangle_sign_and_emit_metadata() {
    if [[ -z "${METADATA_ROOT:-}" || ! -d "${METADATA_ROOT}" ]]; then
        printf 'wrangle: metadata dir %s missing — nothing to sign\n' "${METADATA_ROOT:-}" >&2
        return 1
    fi

    local -a WRANGLE_SUBJECTS
    wrangle_read_subjects

    : > "$OUT"
    local stmts subject line
    stmts="$(mktemp "${RUNNER_TEMP:-/tmp}/attestmeta.XXXXXX")"
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        : > "$stmts"
        wrangle_sign_metadata_statements "$subject" "$stmts"
        if [[ ! -s "$stmts" ]]; then
            printf 'wrangle: no signed metadata produced for %s\n' "$subject" >&2
            rm -f "$stmts"
            return 1
        fi
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '%s\n' "$line" >> "$OUT"
            printf '%s\n' "$line" > "$stmts.line"
            wrangle_push_store "$stmts.line"
            wrangle_push_oci_referrer "$stmts.line"
        done < "$stmts"
        rm -f "$stmts.line"
    done
    rm -f "$stmts"
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
