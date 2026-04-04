#!/bin/bash
set -euo pipefail

# Install OSV-Scanner binary with SLSA provenance verification.
# Usage: install.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/download_verify.sh
source "${SCRIPT_DIR}/../../lib/download_verify.sh"

VERSION="${1:-2.3.5}"
TOOL_NAME="osv-scanner"
SOURCE_REPO="google/osv-scanner"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# SHA-256 checksums (baseline integrity check, always verified)
CHECKSUM_AMD64="bb30c580afe5e757d3e959f4afd08a4795ea505ef84c46962b9a738aa573b41b"
CHECKSUM_ARM64="fa46ad2b3954db5d5335303d45de921613393285d9a93c140b63b40e35e9ce50"

# Check if correct version is already installed
if [[ -x "${BIN_DIR}/${TOOL_NAME}" ]]; then
    installed_version="$("${BIN_DIR}/${TOOL_NAME}" --version 2>/dev/null || true)"
    if [[ "$installed_version" == *"${VERSION}"* ]]; then
        printf 'wrangle: %s %s already installed\n' "$TOOL_NAME" "$VERSION"
        exit 0
    fi
fi

# Detect OS and architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  GOARCH="amd64"; EXPECTED_CHECKSUM="$CHECKSUM_AMD64" ;;
    aarch64) GOARCH="arm64"; EXPECTED_CHECKSUM="$CHECKSUM_ARM64" ;;
    *) printf 'wrangle: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

BINARY_NAME="${TOOL_NAME}_${OS}_${GOARCH}"
URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${BINARY_NAME}"

mkdir -p "$BIN_DIR"

# Download and verify
wrangle_download_verify "$URL" "$EXPECTED_CHECKSUM" "${BIN_DIR}/${TOOL_NAME}"
chmod +x "${BIN_DIR}/${TOOL_NAME}"

# SLSA provenance verification (mandatory for OSV-Scanner).
# OSV-Scanner publishes SLSA provenance — verification MUST succeed.
# If provenance download or verification fails, the install aborts.
# Note: raw curl is used to download the provenance file (not
# wrangle_download_verify) because verifying the provenance file's own
# checksum would be circular — it IS the trust anchor.
PROVENANCE_URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/multiple.intoto.jsonl"
PROVENANCE_PATH="${BIN_DIR}/${TOOL_NAME}.intoto.jsonl"
if ! curl -fsSL -o "$PROVENANCE_PATH" "$PROVENANCE_URL"; then
    printf 'wrangle: FATAL: failed to download SLSA provenance for %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    rm -f "${BIN_DIR}/${TOOL_NAME}"
    exit 1
fi

if ! wrangle_verify_provenance "${BIN_DIR}/${TOOL_NAME}" "$SOURCE_REPO" "v${VERSION}"; then
    printf 'wrangle: FATAL: SLSA provenance verification failed for %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    printf 'wrangle: this may indicate a supply chain attack — aborting\n' >&2
    rm -f "${BIN_DIR}/${TOOL_NAME}" "$PROVENANCE_PATH"
    exit 1
fi

printf 'wrangle: SLSA provenance verified for %s %s\n' "$TOOL_NAME" "$VERSION"
rm -f "$PROVENANCE_PATH"

printf 'wrangle: installed %s %s\n' "$TOOL_NAME" "$VERSION"
