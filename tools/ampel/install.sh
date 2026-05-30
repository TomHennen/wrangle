#!/bin/bash
set -euo pipefail
set -f

# Install ampel (carabiner-dev policy engine) with SLSA provenance verification.
#
# ampel ships a single sigstore-bundle SLSA provenance
# (ampel-v<ver>.provenance.json) covering every release binary as a subject,
# produced by GitHub's actions/attest-build-provenance (predicate
# slsa.dev/provenance/v1). Verification goes through the gh CLI's native
# attestation verifier rather than slsa-verifier: slsa-verifier's
# verify-artifact only handles slsa-github-generator output, and its
# verify-github-attestation is allowlisted to a fixed set of builders, so
# neither accepts ampel's bundle. gh attestation verify is the provenance-tier
# verifier for this build type and supports arbitrary repos.
#
# No fallback: if provenance verification fails, the install aborts. A failed
# check may indicate a supply chain attack.
#
# Usage: install.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/download_verify.sh
source "${SCRIPT_DIR}/../../lib/download_verify.sh"

VERSION="${1:-1.2.1}"
TOOL_NAME="ampel"
SOURCE_REPO="carabiner-dev/ampel"
# The release workflow's identity, validated against the attestation's
# signing certificate (gh --signer-workflow: owner/repo/path, no ref).
SIGNER_WORKFLOW="${SOURCE_REPO}/.github/workflows/release.yaml"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# Idempotency: skip if the requested version is already on disk.
# 'ampel version' prints a "GitVersion: v<ver>" line; match the version token
# exactly so a request for 1.2.1 is not satisfied by an installed v1.2.10.
if [[ -x "${BIN_DIR}/${TOOL_NAME}" ]]; then
    installed_version="$("${BIN_DIR}/${TOOL_NAME}" version 2>/dev/null | awk '/GitVersion/{print $2; exit}')"
    if [[ "$installed_version" == "v${VERSION}" ]]; then
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

# ampel embeds the version in the asset name: ampel-v<ver>-<os>-<arch>.
BINARY_NAME="${TOOL_NAME}-v${VERSION}-${OS}-${GOARCH}"
URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${BINARY_NAME}"

mkdir -p "$BIN_DIR"

# Download binary to a temporary file. Raw curl is intentional: integrity is
# established by gh attestation verify below, not by this download. Retry flags
# match the other installers (see #190).
TMP_BINARY="$(mktemp "${BIN_DIR}/wrangle-dl-XXXXX")"
if ! curl -fsSL --retry 5 --retry-all-errors --retry-max-time 60 -o "$TMP_BINARY" "$URL"; then
    printf 'wrangle: FATAL: failed to download %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    rm -f "$TMP_BINARY"
    exit 1
fi

# Download the SLSA provenance bundle. Verifying the bundle's own integrity
# would be circular — it IS the trust anchor.
PROVENANCE_URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${TOOL_NAME}-v${VERSION}.provenance.json"
PROVENANCE_PATH="${TMP_BINARY}.provenance.json"
if ! curl -fsSL --retry 5 --retry-all-errors --retry-max-time 60 -o "$PROVENANCE_PATH" "$PROVENANCE_URL"; then
    printf 'wrangle: FATAL: failed to download SLSA provenance for %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    rm -f "$TMP_BINARY" "$PROVENANCE_PATH"
    exit 1
fi

# Verify the build provenance — the sole verification method. If this fails,
# the binary MUST NOT be installed.
if ! wrangle_verify_gh_attestation "$TMP_BINARY" "$PROVENANCE_PATH" "$SOURCE_REPO" "$SIGNER_WORKFLOW"; then
    printf 'wrangle: FATAL: SLSA provenance verification failed for %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    printf 'wrangle: this may indicate a supply chain attack — aborting\n' >&2
    rm -f "$TMP_BINARY" "$PROVENANCE_PATH"
    exit 1
fi

# Provenance verified. gh attestation verify binds the binary's digest to a
# genuine carabiner-signed provenance, but NOT to the version string in the
# URL — so a github.com/CDN compromise could serve a genuine *older* signed
# release (with its own valid provenance) at the v<ver> URLs and silently
# downgrade the policy engine. Assert the verified binary reports the expected
# version before trusting it. Running it is safe now: it is cryptographically
# confirmed to be a genuine ampel build.
chmod +x "$TMP_BINARY"
verified_version="$("$TMP_BINARY" version 2>/dev/null | awk '/GitVersion/{print $2; exit}')"
if [[ "$verified_version" != "v${VERSION}" ]]; then
    printf 'wrangle: FATAL: verified binary reports version %s, expected v%s\n' "${verified_version:-unknown}" "$VERSION" >&2
    printf 'wrangle: this may indicate a downgrade attack — aborting\n' >&2
    rm -f "$TMP_BINARY" "$PROVENANCE_PATH"
    exit 1
fi

# Atomically place the verified binary.
mv "$TMP_BINARY" "${BIN_DIR}/${TOOL_NAME}"
rm -f "$PROVENANCE_PATH"

printf 'wrangle: SLSA provenance verified for %s %s\n' "$TOOL_NAME" "$VERSION"
printf 'wrangle: installed %s %s\n' "$TOOL_NAME" "$VERSION"
