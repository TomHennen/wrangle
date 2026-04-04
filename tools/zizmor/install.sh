#!/bin/bash
set -euo pipefail

# Install Zizmor binary with SHA-256 checksum verification.
# Zizmor does not publish SLSA provenance or Sigstore signatures,
# so checksums are the only verification method available.
#
# Usage: install.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/download_verify.sh
source "${SCRIPT_DIR}/../../lib/download_verify.sh"

VERSION="${1:-1.23.1}"
TOOL_NAME="zizmor"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# SHA-256 checksums for the tarball (not the binary inside)
CHECKSUM_AMD64="67a8df0a14352dd81882e14876653d097b99b0f4f6b6fe798edc0320cff27aff"
CHECKSUM_ARM64="3725d7cd7102e4d70827186389f7d5930b6878232930d0a3eb058d7e5b47e658"

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
    x86_64)  RUST_ARCH="x86_64"; EXPECTED_CHECKSUM="$CHECKSUM_AMD64" ;;
    aarch64) RUST_ARCH="aarch64"; EXPECTED_CHECKSUM="$CHECKSUM_ARM64" ;;
    *) printf 'wrangle: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

TARBALL_NAME="${TOOL_NAME}-${RUST_ARCH}-unknown-${OS}-gnu.tar.gz"
URL="https://github.com/woodruffw/${TOOL_NAME}/releases/download/v${VERSION}/${TARBALL_NAME}"

mkdir -p "$BIN_DIR"

# Download and verify tarball
TARBALL_PATH="${BIN_DIR}/${TARBALL_NAME}"
wrangle_download_verify "$URL" "$EXPECTED_CHECKSUM" "$TARBALL_PATH"

# Extract binary from tarball and place atomically
TMP_EXTRACT="$(mktemp -d "${BIN_DIR}/wrangle-extract-XXXXX")"
tar -xzf "$TARBALL_PATH" -C "$TMP_EXTRACT"
mv "${TMP_EXTRACT}/${TOOL_NAME}" "${BIN_DIR}/${TOOL_NAME}"
chmod +x "${BIN_DIR}/${TOOL_NAME}"

# Clean up
rm -f "$TARBALL_PATH"
rm -rf "$TMP_EXTRACT"

printf 'wrangle: installed %s %s\n' "$TOOL_NAME" "$VERSION"
