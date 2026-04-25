#!/bin/bash
set -euo pipefail

# Install syft (Anchore SBOM tool) with Cosign keyless signature verification.
#
# Verification chain:
#   1. cosign verify-blob proves checksums.txt was signed by anchore/syft's
#      release workflow (root of trust = Fulcio CA + Rekor transparency log).
#   2. checksums.txt becomes a trusted source of binary SHA-256 hashes.
#   3. The platform binary is downloaded and verified against the trusted SHA.
#
# No fallback: if cosign verification fails, install aborts. A failed
# signature check may indicate a supply chain attack.
#
# Usage: install.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/download_verify.sh
source "${SCRIPT_DIR}/../../lib/download_verify.sh"

VERSION="${1:-1.42.4}"
TOOL_NAME="syft"
SOURCE_REPO="anchore/syft"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# Idempotency: skip if the requested version is already on disk.
if [[ -x "${BIN_DIR}/${TOOL_NAME}" ]]; then
    installed_version="$("${BIN_DIR}/${TOOL_NAME}" version --output json 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 || true)"
    if [[ "$installed_version" == *"${VERSION}"* ]]; then
        printf 'wrangle: %s %s already installed\n' "$TOOL_NAME" "$VERSION"
        exit 0
    fi
fi

# Detect OS / arch
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  GOARCH="amd64" ;;
    aarch64|arm64) GOARCH="arm64" ;;
    *) printf 'wrangle: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"
WORK_DIR="$(mktemp -d "${BIN_DIR}/wrangle-syft-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

CHECKSUMS_NAME="${TOOL_NAME}_${VERSION}_checksums.txt"
CHECKSUMS_URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${CHECKSUMS_NAME}"
CHECKSUMS_PATH="${WORK_DIR}/${CHECKSUMS_NAME}"
SIG_PATH="${CHECKSUMS_PATH}.sig"
PEM_PATH="${CHECKSUMS_PATH}.pem"

# Download checksums.txt + cosign signature + cert.
# Raw curl is intentional here: integrity is established by cosign
# verify-blob in the next step, not by a checksum.
for spec in "checksums:${CHECKSUMS_URL}:${CHECKSUMS_PATH}" \
            "signature:${CHECKSUMS_URL}.sig:${SIG_PATH}" \
            "certificate:${CHECKSUMS_URL}.pem:${PEM_PATH}"; do
    label="${spec%%:*}"
    rest="${spec#*:}"
    url="${rest%:*}"
    out="${rest##*:}"
    if ! curl -fsSL -o "$out" "$url"; then
        printf 'wrangle: FATAL: failed to download %s for syft %s\n' "$label" "$VERSION" >&2
        exit 1
    fi
done

# Verify checksums.txt with cosign keyless. Identity regex is anchored to
# anchore/syft's release.yaml workflow at a tagged version — anything else
# (forks, other workflows, branch builds) will fail verification.
if ! command -v cosign >/dev/null 2>&1; then
    printf 'wrangle: FATAL: cosign not found on PATH\n' >&2
    printf 'wrangle: install via sigstore/cosign-installer before invoking this script\n' >&2
    exit 1
fi

if ! cosign verify-blob "$CHECKSUMS_PATH" \
    --certificate "$PEM_PATH" \
    --signature "$SIG_PATH" \
    --certificate-identity-regexp '^https://github\.com/anchore/syft/\.github/workflows/release\.yaml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    >/dev/null 2>&1; then
    printf 'wrangle: FATAL: Cosign signature verification failed for syft %s\n' "$VERSION" >&2
    printf 'wrangle: this may indicate a supply chain attack — aborting\n' >&2
    exit 1
fi

# Extract the tarball's SHA-256 from the now-trusted checksums file.
TARBALL_NAME="${TOOL_NAME}_${VERSION}_${OS}_${GOARCH}.tar.gz"
EXPECTED_SHA="$(awk -v f="$TARBALL_NAME" '$2 == f { print $1; exit }' "$CHECKSUMS_PATH")"
if [[ -z "$EXPECTED_SHA" ]]; then
    printf 'wrangle: FATAL: %s not listed in checksums.txt for syft %s\n' "$TARBALL_NAME" "$VERSION" >&2
    exit 1
fi

# Download + checksum-verify the tarball.
TARBALL_URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${TARBALL_NAME}"
TARBALL_PATH="${WORK_DIR}/${TARBALL_NAME}"
if ! wrangle_download_verify "$TARBALL_URL" "$EXPECTED_SHA" "$TARBALL_PATH"; then
    printf 'wrangle: FATAL: failed to download or verify %s\n' "$TARBALL_NAME" >&2
    exit 1
fi

# Extract syft binary, atomically place in $BIN_DIR.
tar -xzf "$TARBALL_PATH" -C "$WORK_DIR" syft
chmod +x "${WORK_DIR}/syft"
mv "${WORK_DIR}/syft" "${BIN_DIR}/${TOOL_NAME}"

printf 'wrangle: Cosign signature verified for syft %s\n' "$VERSION"
printf 'wrangle: installed syft %s to %s\n' "$VERSION" "${BIN_DIR}/${TOOL_NAME}"
