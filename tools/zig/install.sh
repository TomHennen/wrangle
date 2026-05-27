#!/bin/bash
set -euo pipefail

# Install zig (general-purpose programming language; here used as a
# drop-in C/C++ cross-compiler so adopters can build cgo binaries for
# linux/{amd64,arm64} + darwin/{amd64,arm64} from a single
# linux/amd64 GitHub Actions runner).
#
# Verification: hardcoded SHA-256 per binary. Ziglang.org does not
# publish SLSA provenance or Sigstore signatures for binary releases;
# checksums are listed on the release pages and in the JSON index at
# https://ziglang.org/download/index.json. Per CLAUDE.md, the version
# and its SHA-256 are bumped in the same commit (no checksum download).
#
# This installer is invoked by build/actions/go/release when the
# preflight detects that the adopter's .goreleaser.yml uses zig as
# their cgo cross-compiler (CC=zig cc -target ... env templates).
# Standalone adopters of the script can also invoke directly.
#
# Usage: install.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/download_verify.sh
source "${SCRIPT_DIR}/../../lib/download_verify.sh"

VERSION="${1:-0.16.0}"
TOOL_NAME="zig"
BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"

# Idempotency: skip if the requested version is already on disk.
# `zig version` prints a bare semver line ("0.16.0\n") — a thin
# contract. If upstream ever prefixes/suffixes the output, this
# equality check silently misses and the script re-installs (safe,
# just slower). Update the comparison shape if that ever happens.
if [[ -x "${BIN_DIR}/${TOOL_NAME}" ]]; then
    installed_version="$("${BIN_DIR}/${TOOL_NAME}" version 2>/dev/null || true)"
    if [[ "$installed_version" == "$VERSION" ]]; then
        printf 'wrangle: %s %s already installed\n' "$TOOL_NAME" "$VERSION"
        exit 0
    fi
fi

# Detect arch. Zig publishes per-(arch, os) tarballs; we install only
# the runner-native one (the cross-compile is done BY zig at goreleaser
# runtime, not by picking a different host binary).
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  ZIG_ARCH="x86_64" ;;
    aarch64|arm64) ZIG_ARCH="aarch64" ;;
    *) printf 'wrangle: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

# Hardcoded SHA-256 per (version, arch). When bumping VERSION, fetch
# the published SHA-256 for each arch from
# https://ziglang.org/download/index.json — do NOT download alongside
# the binary, per CLAUDE.md "No downloading checksums from the same
# source as binaries."
case "${VERSION}:${ZIG_ARCH}" in
    "0.16.0:x86_64")  EXPECTED_SHA="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;;
    "0.16.0:aarch64") EXPECTED_SHA="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;;
    *)
        printf 'wrangle: FATAL: no hardcoded SHA-256 for zig %s on %s\n' "$VERSION" "$ZIG_ARCH" >&2
        printf 'wrangle: bump the case-block in tools/zig/install.sh in the same commit as the version\n' >&2
        exit 1
        ;;
esac

mkdir -p "$BIN_DIR"
WORK_DIR="$(mktemp -d "${BIN_DIR}/wrangle-zig-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

TARBALL_NAME="zig-${ZIG_ARCH}-linux-${VERSION}.tar.xz"
TARBALL_URL="https://ziglang.org/download/${VERSION}/${TARBALL_NAME}"
TARBALL_PATH="${WORK_DIR}/${TARBALL_NAME}"

if ! wrangle_download_verify "$TARBALL_URL" "$EXPECTED_SHA" "$TARBALL_PATH"; then
    printf 'wrangle: FATAL: failed to download or verify %s\n' "$TARBALL_NAME" >&2
    exit 1
fi

# Extract — zig ships as a self-contained tree containing the `zig`
# binary plus its `lib/` (stdlib + cross-compile target SDKs). Both
# the binary and the lib dir need to live next to each other; zig
# resolves lib/ relative to the binary path. We extract to BIN_DIR
# and symlink the binary.
tar -xJf "$TARBALL_PATH" -C "$WORK_DIR"
ZIG_TREE="${WORK_DIR}/zig-${ZIG_ARCH}-linux-${VERSION}"
if [[ ! -x "${ZIG_TREE}/zig" ]]; then
    printf 'wrangle: FATAL: extracted tree missing zig binary at %s\n' "$ZIG_TREE" >&2
    exit 1
fi

# Move tree atomically into BIN_DIR (next to other wrangle tools),
# then symlink the binary as `zig` at the top level of BIN_DIR.
INSTALL_TREE="${BIN_DIR}/zig-${VERSION}"
rm -rf "$INSTALL_TREE"
mv "$ZIG_TREE" "$INSTALL_TREE"
ln -sf "${INSTALL_TREE}/zig" "${BIN_DIR}/${TOOL_NAME}"

printf 'wrangle: installed zig %s to %s (lib tree at %s)\n' "$VERSION" "${BIN_DIR}/${TOOL_NAME}" "$INSTALL_TREE"
