#!/bin/bash
set -euo pipefail
set -f

# Install ampel (Carabiner policy verifier) from its release binaries, with
# SLSA-provenance verification.
#
# Verification chain:
#   1. cosign verify-blob-attestation proves the release's provenance bundle
#      was signed by carabiner-dev/ampel's release workflow at the exact
#      requested version tag (root of trust = Fulcio CA + Rekor transparency
#      log) AND that the downloaded binary's hash is a subject of it.
#   2. Nothing else is trusted: no checksums file, no fallback. A failed
#      verification may indicate a supply chain attack — install aborts.
#
# A release binary (not `go install` from tools/go.mod) because this runs in
# adopters' publish jobs, where a Go toolchain can't be assumed and a
# multi-minute source build would tax every release. The version below must
# stay equal to the ampel version in tools/go.mod (divergence-fail test in
# test.bats), so Dependabot bumps reach both install paths together.
#
# Usage: install_ampel.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/env.sh
source "${SCRIPT_DIR}/../../lib/env.sh"

VERSION="${1:-v1.3.0}"
SOURCE_REPO="carabiner-dev/ampel"
BIN_DIR="$WRANGLE_BIN_DIR"

# Idempotency: skip if the requested version is already on disk.
if [[ -x "${BIN_DIR}/ampel" ]]; then
    if "${BIN_DIR}/ampel" version 2>/dev/null | grep -q "GitVersion:.*${VERSION}"; then
        printf 'wrangle: ampel %s already installed\n' "$VERSION"
        exit 0
    fi
fi

if ! command -v cosign >/dev/null 2>&1; then
    printf 'wrangle: FATAL: cosign not found on PATH\n' >&2
    printf 'wrangle: install via sigstore/cosign-installer before invoking this script\n' >&2
    exit 1
fi

# Detect OS / arch; ampel releases raw per-platform binaries.
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
    linux|darwin) ;;
    *) printf 'wrangle: unsupported OS: %s\n' "$OS" >&2; exit 1 ;;
esac
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)        GOARCH="amd64" ;;
    aarch64|arm64) GOARCH="arm64" ;;
    *) printf 'wrangle: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"
WORK_DIR="$(mktemp -d "${BIN_DIR}/wrangle-ampel-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

BINARY_NAME="ampel-${VERSION}-${OS}-${GOARCH}"
RELEASE_URL="https://github.com/${SOURCE_REPO}/releases/download/${VERSION}"
BINARY_PATH="${WORK_DIR}/${BINARY_NAME}"
PROVENANCE_PATH="${WORK_DIR}/provenance.json"

# Raw curl is intentional: integrity is established by the provenance
# verification below, not by a checksum. --retry-all-errors covers the 5xx
# responses GitHub's release CDN periodically returns; --retry-max-time caps
# a sustained outage so it fails promptly rather than hanging the runner.
for spec in "binary:${RELEASE_URL}/${BINARY_NAME}:${BINARY_PATH}" \
            "provenance:${RELEASE_URL}/ampel-${VERSION}.provenance.json:${PROVENANCE_PATH}"; do
    label="${spec%%:*}"
    rest="${spec#*:}"
    url="${rest%:*}"
    out="${rest##*:}"
    if ! curl -fsSL --retry 5 --retry-all-errors --retry-max-time 60 -o "$out" "$url"; then
        printf 'wrangle: FATAL: failed to download %s for ampel %s\n' "$label" "$VERSION" >&2
        exit 1
    fi
done

# The provenance is a sigstore bundle whose in-toto subjects are the release
# binaries; cosign checks the signature, the signer identity (ampel's release
# workflow at exactly the requested tag), and that the downloaded binary's
# hash is among the subjects — one call binds all three.
if ! cosign verify-blob-attestation --bundle "$PROVENANCE_PATH" --new-bundle-format \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    --certificate-identity "https://github.com/${SOURCE_REPO}/.github/workflows/release.yaml@refs/tags/${VERSION}" \
    --certificate-github-workflow-repository "$SOURCE_REPO" \
    --type 'https://slsa.dev/provenance/v1' \
    "$BINARY_PATH" >/dev/null 2>&1; then
    printf 'wrangle: FATAL: provenance verification failed for ampel %s (%s)\n' "$VERSION" "$BINARY_NAME" >&2
    printf 'wrangle: this may indicate a supply chain attack — aborting\n' >&2
    exit 1
fi

chmod +x "$BINARY_PATH"
mv "$BINARY_PATH" "${BIN_DIR}/ampel"
printf 'wrangle: installed ampel %s (provenance verified) to %s\n' "$VERSION" "${BIN_DIR}/ampel"
