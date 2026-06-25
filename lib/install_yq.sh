#!/bin/bash
set -euo pipefail
set -f

# lib/install_yq.sh — install mikefarah/yq (the standalone Go YAML parser) into
# $WRANGLE_BIN_DIR so the orchestrator can read tools/catalog.yaml with a real
# YAML parser. yq is orchestrator infra, not an adapter tool: it must be on PATH
# before run.sh parses the catalog, so setup.sh installs it at scan setup.
#
# Verification is a hardcoded SHA-256 (DEP_MGMT integrity tier 3). mikefarah/yq
# also publishes a cosign-signed checksums bundle (tier 2), but cosign is not on
# PATH at scan setup — pulling it in solely to parse a wrangle-committed catalog
# is disproportionate, and tier 2 buys no freshness here (both tiers are manual,
# flagged against #264). Version + checksum bump together in a single commit.
#
# Usage: install_yq.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=download_verify.sh
source "${SCRIPT_DIR}/download_verify.sh"

VERSION="${1:-4.53.3}"
SOURCE_REPO="mikefarah/yq"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# SHA-256 of the linux release binaries for the pinned version, from the
# cosign-signed checksums of mikefarah/yq v4.53.3. Bump with VERSION.
SHA256_AMD64="fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4"
SHA256_ARM64="578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea"

# Idempotency: skip if the requested version is already on disk.
if [[ -x "${BIN_DIR}/yq" ]]; then
    installed="$("${BIN_DIR}/yq" --version 2>/dev/null || true)"
    if [[ "$installed" == *"${VERSION}"* ]]; then
        printf 'wrangle: yq %s already installed\n' "$VERSION"
        exit 0
    fi
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)        GOARCH="amd64"; EXPECTED_SHA="$SHA256_AMD64" ;;
    aarch64|arm64) GOARCH="arm64"; EXPECTED_SHA="$SHA256_ARM64" ;;
    *) printf 'wrangle: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"
WORK_DIR="$(mktemp -d "${BIN_DIR}/wrangle-yq-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

BIN_NAME="yq_linux_${GOARCH}"
BIN_URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${BIN_NAME}"
BIN_PATH="${WORK_DIR}/${BIN_NAME}"

if ! wrangle_download_verify "$BIN_URL" "$EXPECTED_SHA" "$BIN_PATH"; then
    printf 'wrangle: FATAL: failed to download or verify yq %s\n' "$VERSION" >&2
    exit 1
fi

chmod +x "$BIN_PATH"
mv "$BIN_PATH" "${BIN_DIR}/yq"

printf 'wrangle: installed yq %s to %s\n' "$VERSION" "${BIN_DIR}/yq"
