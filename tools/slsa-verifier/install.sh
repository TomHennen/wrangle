#!/bin/bash
set -euo pipefail
set -f

# Install the official slsa-verifier release binary with a hardcoded
# SHA-256 per architecture.
#
# Why a binary, not a `tool` directive in tools/go.mod: slsa-verifier's
# release pins a dependency graph upstream froze at release time; building
# it from a Dependabot-refreshed graph produces a verifier binary upstream
# never tested, and carrying the frozen go.mod in-tree advertises every
# since-published advisory in that graph to source scanners with no
# fixable version to bump to. The release binary is the same artifact the
# official installer action ships (actions/scan installs it that way).
#
# Why hardcoded checksums, not wrangle_verify_provenance: verifying
# slsa-verifier's own provenance needs slsa-verifier — circular. The
# hashes below were cross-checked against the release's .intoto.jsonl
# provenance with an independently source-built (sum.golang.org-verified)
# slsa-verifier before being committed. Version + checksum updates are a
# single atomic commit.
#
# Usage: install.sh [version]

VERSION="${1:-2.7.1}"
TOOL_NAME="slsa-verifier"
SOURCE_REPO="slsa-framework/slsa-verifier"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/download_verify.sh
source "${SCRIPT_DIR}/../../lib/download_verify.sh"

CHECKSUM_AMD64="946dbec729094195e88ef78e1734324a27869f03e2c6bd2f61cbc06bd5350339"
CHECKSUM_ARM64="5d3b2349ede7bfec19e7a21569f18b9f7410145ad12e9584b175370669e14061"

# Check if correct version is already installed. `version` reports an
# unprefixed "GitVersion:    2.7.1" — match without a leading v.
if [[ -x "${BIN_DIR}/${TOOL_NAME}" ]]; then
    installed_version="$("${BIN_DIR}/${TOOL_NAME}" version 2>/dev/null || true)"
    if [[ "$installed_version" == *"GitVersion:"*"${VERSION}"* ]]; then
        printf 'wrangle: %s %s already installed\n' "$TOOL_NAME" "$VERSION"
        exit 0
    fi
fi

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
if [[ "$OS" != "linux" ]]; then
    printf 'wrangle: unsupported OS for %s install: %s\n' "$TOOL_NAME" "$OS" >&2
    exit 1
fi
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  GOARCH="amd64"; EXPECTED_CHECKSUM="$CHECKSUM_AMD64" ;;
    aarch64) GOARCH="arm64"; EXPECTED_CHECKSUM="$CHECKSUM_ARM64" ;;
    *) printf 'wrangle: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

URL="https://github.com/${SOURCE_REPO}/releases/download/v${VERSION}/${TOOL_NAME}-${OS}-${GOARCH}"

mkdir -p "$BIN_DIR"
wrangle_download_verify "$URL" "$EXPECTED_CHECKSUM" "${BIN_DIR}/${TOOL_NAME}"
chmod +x "${BIN_DIR}/${TOOL_NAME}"

printf 'wrangle: checksum verified for %s %s\n' "$TOOL_NAME" "$VERSION"
printf 'wrangle: installed %s %s\n' "$TOOL_NAME" "$VERSION"
