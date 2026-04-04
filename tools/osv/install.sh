#!/bin/bash
set -euo pipefail

# Install OSV-Scanner binary with SLSA provenance verification.
# OSV-Scanner publishes SLSA provenance attestations, so provenance is
# the sole verification method. No checksum fallback — if provenance
# verification fails, the install aborts.
#
# Usage: install.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/download_verify.sh
source "${SCRIPT_DIR}/../../lib/download_verify.sh"

VERSION="${1:-2.3.5}"
TOOL_NAME="osv-scanner"
SOURCE_REPO="google/osv-scanner"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

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
    x86_64)  GOARCH="amd64" ;;
    aarch64) GOARCH="arm64" ;;
    *) printf 'wrangle: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

BINARY_NAME="${TOOL_NAME}_${OS}_${GOARCH}"
URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${BINARY_NAME}"

mkdir -p "$BIN_DIR"

# Download binary to a temporary file
TMP_BINARY="$(mktemp "${BIN_DIR}/wrangle-dl-XXXXX")"
if ! curl -fsSL -o "$TMP_BINARY" "$URL"; then
    printf 'wrangle: FATAL: failed to download %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    rm -f "$TMP_BINARY"
    exit 1
fi

# Download SLSA provenance attestation
# Note: raw curl is used (not wrangle_download_verify) because verifying
# the provenance file's own integrity would be circular — it IS the trust anchor.
PROVENANCE_URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/multiple.intoto.jsonl"
PROVENANCE_PATH="${TMP_BINARY}.intoto.jsonl"
if ! curl -fsSL -o "$PROVENANCE_PATH" "$PROVENANCE_URL"; then
    printf 'wrangle: FATAL: failed to download SLSA provenance for %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    rm -f "$TMP_BINARY" "$PROVENANCE_PATH"
    exit 1
fi

# Verify SLSA provenance — this is the sole verification method.
# If this fails, the binary MUST NOT be installed.
if ! wrangle_verify_provenance "$TMP_BINARY" "$SOURCE_REPO" "v${VERSION}"; then
    printf 'wrangle: FATAL: SLSA provenance verification failed for %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    printf 'wrangle: this may indicate a supply chain attack — aborting\n' >&2
    rm -f "$TMP_BINARY" "$PROVENANCE_PATH"
    exit 1
fi

# Provenance verified — atomically place binary
mv "$TMP_BINARY" "${BIN_DIR}/${TOOL_NAME}"
chmod +x "${BIN_DIR}/${TOOL_NAME}"
rm -f "$PROVENANCE_PATH"

printf 'wrangle: SLSA provenance verified for %s %s\n' "$TOOL_NAME" "$VERSION"
printf 'wrangle: installed %s %s\n' "$TOOL_NAME" "$VERSION"
