#!/bin/bash
# lib/download_verify.sh — Shared download and verification functions for wrangle.
# Sourced by install scripts; not executed directly.
#
# Provides:
#   wrangle_download_verify  — download a file and verify its SHA-256 checksum
#   wrangle_verify_provenance — verify SLSA provenance via slsa-verifier
#   wrangle_verify_signature  — verify Sigstore signature via cosign

set -euo pipefail

# Download a file and verify its SHA-256 checksum.
# Retries up to 3 times with exponential backoff (1s, 2s, 4s) on transient
# download failures.
# On checksum mismatch or exhausted retries, deletes the temp file and exits 1.
#
# Usage: wrangle_download_verify <url> <expected_sha256> <output_path>
wrangle_download_verify() {
    if [[ $# -ne 3 ]]; then
        printf 'Usage: wrangle_download_verify <url> <expected_sha256> <output_path>\n' >&2
        return 1
    fi

    local url="$1"
    local expected_sha256="$2"
    local output_path="$3"

    local tmp_dir
    tmp_dir="$(dirname "$output_path")"
    local tmp_file
    tmp_file="$(mktemp "${tmp_dir}/wrangle-dl-XXXXX")"

    local max_retries=3
    local attempt=0
    local backoff=1
    local downloaded=false

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        if curl -fsSL -o "$tmp_file" "$url"; then
            downloaded=true
            break
        fi
        if [[ $attempt -lt $max_retries ]]; then
            printf 'wrangle: download attempt %d/%d failed, retrying in %ds...\n' "$attempt" "$max_retries" "$backoff" >&2
            sleep "$backoff"
            backoff=$((backoff * 2))
        fi
    done

    if [[ "$downloaded" != "true" ]]; then
        printf 'wrangle: download failed after %d attempts: %s\n' "$max_retries" "$url" >&2
        rm -f "$tmp_file"
        return 1
    fi

    # Verify checksum
    local actual_sha256
    actual_sha256="$(sha256sum "$tmp_file" | cut -d' ' -f1)"

    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        printf 'wrangle: checksum mismatch for %s\n' "$url" >&2
        printf 'wrangle:   expected: %s\n' "$expected_sha256" >&2
        printf 'wrangle:   actual:   %s\n' "$actual_sha256" >&2
        rm -f "$tmp_file"
        return 1
    fi

    # Atomic move to final location
    mv "$tmp_file" "$output_path"
    return 0
}

# Verify SLSA provenance for a downloaded artifact via slsa-verifier.
#
# Usage: wrangle_verify_provenance <artifact_path> <source_repo> <expected_tag>
# Returns: 0 on success, 1 on verification failure or tool not available
#
# IMPORTANT: This function returns 1 (failure) if slsa-verifier is not
# installed. Callers MUST NOT fall back to a weaker verification method
# on failure — a failed provenance check may indicate a supply chain attack.
wrangle_verify_provenance() {
    if [[ $# -ne 3 ]]; then
        printf 'Usage: wrangle_verify_provenance <artifact_path> <source_repo> <expected_tag>\n' >&2
        return 1
    fi

    local artifact_path="$1"
    local source_repo="$2"
    local expected_tag="$3"

    if ! command -v slsa-verifier >/dev/null 2>&1; then
        printf 'wrangle: slsa-verifier not found — cannot verify provenance\n' >&2
        printf 'wrangle: install slsa-verifier or the provenance check will fail\n' >&2
        return 1
    fi

    if slsa-verifier verify-artifact "$artifact_path" \
        --provenance-path "${artifact_path}.intoto.jsonl" \
        --source-uri "github.com/${source_repo}" \
        --source-tag "$expected_tag"; then
        return 0
    else
        printf 'wrangle: SLSA provenance verification FAILED for %s\n' "$artifact_path" >&2
        return 1
    fi
}

# Verify Sigstore signature for a downloaded artifact via cosign.
#
# Usage: wrangle_verify_signature <artifact_path> <expected_identity> <expected_issuer>
# Returns: 0 on success, 1 on verification failure or tool not available
#
# IMPORTANT: This function returns 1 (failure) if cosign is not installed.
# Callers MUST NOT fall back to a weaker verification method on failure.
wrangle_verify_signature() {
    if [[ $# -ne 3 ]]; then
        printf 'Usage: wrangle_verify_signature <artifact_path> <expected_identity> <expected_issuer>\n' >&2
        return 1
    fi

    local artifact_path="$1"
    local expected_identity="$2"
    local expected_issuer="$3"

    if ! command -v cosign >/dev/null 2>&1; then
        printf 'wrangle: cosign not found — cannot verify signature\n' >&2
        printf 'wrangle: install cosign or the signature check will fail\n' >&2
        return 1
    fi

    if cosign verify-blob "$artifact_path" \
        --certificate-identity "$expected_identity" \
        --certificate-oidc-issuer "$expected_issuer"; then
        return 0
    else
        printf 'wrangle: Sigstore signature verification FAILED for %s\n' "$artifact_path" >&2
        return 1
    fi
}
