#!/bin/bash
set -euo pipefail
set -f

# Install ast-grep with hardcoded SHA-256 checksum verification.
#
# Why checksum-only: ast-grep does not publish SLSA provenance
# (`*.intoto.jsonl`) or Sigstore signatures (`*.sig` / `*.pem`) with
# its GitHub releases — its release workflow uses
# `taiki-e/upload-rust-binary-action` which uploads only the binary
# zip. Checksum verification with hardcoded values in this script is
# the strongest integrity tier available for this upstream. Per
# CLAUDE.md "Install Script Contract" we MUST NOT fall back from a
# stronger tier to a weaker one — but here checksum IS the strongest,
# not a fallback.
#
# Checksums below are hardcoded — never downloaded — to avoid the
# circular trust problem of fetching the checksums file from the same
# origin as the binary. A version bump and its checksum update MUST be
# in the same commit (CLAUDE.md "Supply Chain Discipline").
#
# Usage: install.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/download_verify.sh
source "${SCRIPT_DIR}/../../lib/download_verify.sh"

VERSION="${1:-0.43.0}"
TOOL_NAME="ast-grep"
SOURCE_REPO="ast-grep/ast-grep"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# Idempotency: skip if the requested version is already installed.
if [[ -x "${BIN_DIR}/${TOOL_NAME}" ]]; then
    installed_version="$("${BIN_DIR}/${TOOL_NAME}" --version 2>/dev/null | awk '{print $2}' || true)"
    if [[ "$installed_version" == "${VERSION}" ]]; then
        printf 'wrangle: %s %s already installed\n' "$TOOL_NAME" "$VERSION"
        exit 0
    fi
fi

# Detect OS / arch and select the matching release asset.
# Asset names follow ast-grep's release convention:
#   app-<arch>-<os>.zip
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "${OS}/${ARCH}" in
    linux/x86_64)
        ASSET="app-x86_64-unknown-linux-gnu.zip"
        EXPECTED_SHA="a26253a9c821d935f7e383e40f0de7c2ca62a4121de1f73a6d81ec32eae631e0"
        ;;
    linux/aarch64|linux/arm64)
        ASSET="app-aarch64-unknown-linux-gnu.zip"
        EXPECTED_SHA="e706846148493967f3ab8011334817edd86ce5acbec10718b2a7b40799c640ff"
        ;;
    darwin/x86_64)
        ASSET="app-x86_64-apple-darwin.zip"
        EXPECTED_SHA="6d703090b106747b2f56086b6ccc7e798fe78bcae70257aa20519b220153555b"
        ;;
    darwin/arm64|darwin/aarch64)
        ASSET="app-aarch64-apple-darwin.zip"
        EXPECTED_SHA="8c847d0a29aa4b3101b3361e0b3ee7fb53c7e497adc9ed1afc9615538cd40782"
        ;;
    *)
        printf 'wrangle: FATAL: unsupported OS/arch for %s: %s/%s\n' "$TOOL_NAME" "$OS" "$ARCH" >&2
        exit 1
        ;;
esac

URL="https://github.com/${SOURCE_REPO}/releases/download/${VERSION}/${ASSET}"

mkdir -p "$BIN_DIR"
WORK_DIR="$(mktemp -d "${BIN_DIR}/wrangle-ast-grep-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

ZIP_PATH="${WORK_DIR}/${ASSET}"

# Download + checksum-verify the zip via the shared helper.
# wrangle_download_verify retries with exponential backoff, aborts on
# checksum mismatch, and uses atomic mv to its output path.
if ! wrangle_download_verify "$URL" "$EXPECTED_SHA" "$ZIP_PATH"; then
    printf 'wrangle: FATAL: failed to download or verify %s %s\n' "$TOOL_NAME" "$VERSION" >&2
    exit 1
fi

# Extract the ast-grep binary. The archive contains two binaries:
# `ast-grep` (the canonical name) and `sg` (a short alias). We only
# install `ast-grep`; the wrangle linter wrapper invokes it by name.
#
# Use python3 to unzip — it is in every wrangle CI image (Ubuntu base)
# and avoids pulling `unzip` as a new dependency. If python3 ever
# becomes optional we can switch to `unzip` and add it to the Dockerfile.
if ! python3 -c "
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extract('ast-grep', sys.argv[2])
" "$ZIP_PATH" "$WORK_DIR"; then
    printf 'wrangle: FATAL: failed to extract ast-grep from %s\n' "$ZIP_PATH" >&2
    exit 1
fi

chmod +x "${WORK_DIR}/ast-grep"

# Atomic mv to final location prevents TOCTOU races where a concurrent
# process could observe a half-written binary.
mv "${WORK_DIR}/ast-grep" "${BIN_DIR}/${TOOL_NAME}"

printf 'wrangle: SHA-256 verified for %s %s\n' "$TOOL_NAME" "$VERSION"
printf 'wrangle: installed %s %s to %s\n' "$TOOL_NAME" "$VERSION" "${BIN_DIR}/${TOOL_NAME}"
