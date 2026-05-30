#!/bin/bash
set -euo pipefail
set -f

# Install ampel (carabiner-dev policy engine) with SLSA provenance verification.
#
# ampel ships a single sigstore-bundle SLSA provenance
# (ampel-v<ver>.provenance.json) covering every release binary as a subject,
# produced by GitHub's actions/attest-build-provenance (predicate
# slsa.dev/provenance/v1, buildType actions.github.io/buildtypes/workflow/v1).
# Verification goes through slsa-verifier with an explicit --builder-id naming
# ampel's release workflow: unlike slsa-github-generator provenance,
# slsa-verifier cannot infer a trusted builder for this build type.
#
# No fallback: if provenance verification fails, the install aborts. A failed
# check may indicate a supply chain attack. (If slsa-verifier ever stops
# accepting ampel's bundle, the documented fallback is a hardcoded SHA-256
# pin per carabiner-dev/actions/install/ampel-bootstrap — never a weaker
# runtime fallback; see CLAUDE.md integrity tiers.)
#
# Usage: install.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/download_verify.sh
source "${SCRIPT_DIR}/../../lib/download_verify.sh"

VERSION="${1:-1.2.1}"
TOOL_NAME="ampel"
SOURCE_REPO="carabiner-dev/ampel"
# attest-build-provenance signs with the release workflow's OIDC identity;
# slsa-verifier matches this against the provenance builder.id.
BUILDER_ID="https://github.com/${SOURCE_REPO}/.github/workflows/release.yaml@refs/tags/v${VERSION}"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# Idempotency: skip if the requested version is already on disk.
# 'ampel version' prints a "GitVersion: v<ver>" line.
if [[ -x "${BIN_DIR}/${TOOL_NAME}" ]]; then
    installed_version="$("${BIN_DIR}/${TOOL_NAME}" version 2>/dev/null | grep -i 'GitVersion' || true)"
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

# ampel embeds the version in the asset name: ampel-v<ver>-<os>-<arch>.
BINARY_NAME="${TOOL_NAME}-v${VERSION}-${OS}-${GOARCH}"
URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${BINARY_NAME}"

mkdir -p "$BIN_DIR"

# Download binary to a temporary file. Raw curl is intentional: integrity is
# established by slsa-verifier below, not by this download. Retry flags match
# the other installers (see #190).
TMP_BINARY="$(mktemp "${BIN_DIR}/wrangle-dl-XXXXX")"
if ! curl -fsSL --retry 5 --retry-all-errors --retry-max-time 60 -o "$TMP_BINARY" "$URL"; then
    printf 'wrangle: FATAL: failed to download %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    rm -f "$TMP_BINARY"
    exit 1
fi

# Download the SLSA provenance bundle. Saved as <binary>.intoto.jsonl so the
# shared helper finds it; upstream's filename is ampel-v<ver>.provenance.json.
# Verifying the provenance's own integrity would be circular — it IS the trust
# anchor.
PROVENANCE_URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${TOOL_NAME}-v${VERSION}.provenance.json"
PROVENANCE_PATH="${TMP_BINARY}.intoto.jsonl"
if ! curl -fsSL --retry 5 --retry-all-errors --retry-max-time 60 -o "$PROVENANCE_PATH" "$PROVENANCE_URL"; then
    printf 'wrangle: FATAL: failed to download SLSA provenance for %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    rm -f "$TMP_BINARY" "$PROVENANCE_PATH"
    exit 1
fi

# Verify SLSA provenance — the sole verification method. If this fails, the
# binary MUST NOT be installed.
if ! wrangle_verify_provenance "$TMP_BINARY" "$SOURCE_REPO" "v${VERSION}" "$BUILDER_ID"; then
    printf 'wrangle: FATAL: SLSA provenance verification failed for %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    printf 'wrangle: this may indicate a supply chain attack — aborting\n' >&2
    rm -f "$TMP_BINARY" "$PROVENANCE_PATH"
    exit 1
fi

# Provenance verified — atomically place binary.
mv "$TMP_BINARY" "${BIN_DIR}/${TOOL_NAME}"
chmod +x "${BIN_DIR}/${TOOL_NAME}"
rm -f "$PROVENANCE_PATH"

printf 'wrangle: SLSA provenance verified for %s %s\n' "$TOOL_NAME" "$VERSION"
printf 'wrangle: installed %s %s\n' "$TOOL_NAME" "$VERSION"
