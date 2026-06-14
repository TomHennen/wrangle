#!/bin/bash
set -euo pipefail
set -f

# Install osv-scanner from Google's prebuilt release binary, verified against
# its SLSA build-provenance attestation (SLSA Build L3, slsa-github-generator).
#
# Verification: cosign verify-blob-attestation checks the downloaded binary's
# digest is a subject of multiple.intoto.jsonl, signed keyless by the SLSA
# generator's reusable workflow (root of trust = Fulcio CA + Rekor). No
# fallback: a failed check aborts the install — it may signal a supply chain
# attack. The canonical upstream verifier is `slsa-verifier verify-artifact`;
# cosign is used here because wrangle already depends on it.
#
# Usage: install.sh [version]

VERSION="${1:-2.3.8}"
TOOL_NAME="osv-scanner"
SOURCE_REPO="google/osv-scanner"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# The SLSA generator reusable workflow that signs osv-scanner's provenance.
# Pinned to the generator version osv currently uses — bump when osv upgrades
# slsa-github-generator, or the provenance stops verifying.
PROVENANCE_IDENTITY="https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@refs/tags/v2.1.0"
PROVENANCE_ISSUER="https://token.actions.githubusercontent.com"

# Idempotency: skip if the requested version is already on disk.
if [[ -x "${BIN_DIR}/${TOOL_NAME}" ]]; then
    installed="$("${BIN_DIR}/${TOOL_NAME}" --version 2>/dev/null | head -1 || true)"
    if [[ "$installed" == *"${VERSION}"* ]]; then
        printf 'wrangle: %s %s already installed\n' "$TOOL_NAME" "$VERSION"
        exit 0
    fi
fi

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) GOARCH="amd64" ;;
    aarch64|arm64) GOARCH="arm64" ;;
    *) printf 'wrangle: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

if ! command -v cosign >/dev/null 2>&1; then
    printf 'wrangle: FATAL: cosign not found on PATH\n' >&2
    printf 'wrangle: install via sigstore/cosign-installer before invoking this script\n' >&2
    exit 1
fi

mkdir -p "$BIN_DIR"
WORK_DIR="$(mktemp -d "${BIN_DIR}/wrangle-osv-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

BIN_NAME="osv-scanner_${OS}_${GOARCH}"
[[ "$OS" == "windows" ]] && BIN_NAME="${BIN_NAME}.exe"
BASE_URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}"
BIN_PATH="${WORK_DIR}/${BIN_NAME}"
PROV_PATH="${WORK_DIR}/multiple.intoto.jsonl"

# Raw curl: integrity is established by cosign verify-blob-attestation next, not
# by a checksum. --retry handles GitHub's release CDN returning transient 5xx.
for spec in "binary:${BASE_URL}/${BIN_NAME}:${BIN_PATH}" \
            "provenance:${BASE_URL}/multiple.intoto.jsonl:${PROV_PATH}"; do
    label="${spec%%:*}"; rest="${spec#*:}"; url="${rest%:*}"; out="${rest##*:}"
    if ! curl -fsSL --retry 5 --retry-all-errors --retry-max-time 60 -o "$out" "$url"; then
        printf 'wrangle: FATAL: failed to download %s for osv-scanner %s\n' "$label" "$VERSION" >&2
        exit 1
    fi
done

# Verify the binary against its SLSA provenance. Retry once for transient
# Sigstore I/O (TUF refresh); a forged binary fails both attempts.
wrangle_osv_verify() {
    cosign verify-blob-attestation \
        --bundle "$PROV_PATH" \
        --new-bundle-format \
        --certificate-identity "$PROVENANCE_IDENTITY" \
        --certificate-oidc-issuer "$PROVENANCE_ISSUER" \
        "$BIN_PATH"
}
if ! verify_err="$(wrangle_osv_verify 2>&1)"; then
    printf 'wrangle: provenance verify failed; retrying once for transient Sigstore I/O\n' >&2
    sleep "${WRANGLE_RETRY_DELAY:-5}"
    if ! verify_err="$(wrangle_osv_verify 2>&1)"; then
        printf '%s\n' "$verify_err" >&2
        printf 'wrangle: FATAL: SLSA provenance verification failed for osv-scanner %s\n' "$VERSION" >&2
        printf 'wrangle: this may indicate a supply chain attack — aborting\n' >&2
        exit 1
    fi
fi

chmod +x "$BIN_PATH"
mv "$BIN_PATH" "${BIN_DIR}/${TOOL_NAME}"
printf 'wrangle: SLSA provenance verified for osv-scanner %s\n' "$VERSION"
printf 'wrangle: installed osv-scanner %s to %s\n' "$VERSION" "${BIN_DIR}/${TOOL_NAME}"
