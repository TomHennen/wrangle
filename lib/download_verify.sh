#!/bin/bash
# lib/download_verify.sh — Shared download and verification functions for wrangle.
# Sourced by install scripts; not executed directly.
#
# Provides:
#   wrangle_download_verify  — download a file and verify its SHA-256 checksum

set -euo pipefail
set -f

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
