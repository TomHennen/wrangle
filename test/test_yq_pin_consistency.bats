#!/usr/bin/env bats

# Divergence guard for the yq pin, which lives in two places with no shared
# source: lib/install_yq.sh (what setup.sh installs onto adopters' PATH) and
# test/Dockerfile (what the unit suite's read_catalog tests exercise). The
# version and both per-arch SHA-256s must agree, so the yq the tests prove out
# can't drift from the one wrangle ships. Fails closed on any mismatch.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
}

@test "yq version and checksums agree between lib/install_yq.sh and test/Dockerfile" {
    cd "$REPO_ROOT"

    local installer="lib/install_yq.sh" dockerfile="test/Dockerfile"
    local sha_re='[0-9a-f]{64}'

    local inst_version inst_amd64 inst_arm64
    inst_version="$(sed -nE 's/^VERSION="\$\{1:-([0-9.]+)\}"$/\1/p' "$installer")"
    inst_amd64="$(sed -nE "s/^SHA256_AMD64=\"($sha_re)\"$/\1/p" "$installer")"
    inst_arm64="$(sed -nE "s/^SHA256_ARM64=\"($sha_re)\"$/\1/p" "$installer")"

    local dock_version dock_amd64 dock_arm64
    dock_version="$(sed -nE 's/^ARG YQ_VERSION=([0-9.]+)$/\1/p' "$dockerfile")"
    dock_amd64="$(sed -nE "s/^ARG YQ_CHECKSUM_AMD64=($sha_re)$/\1/p" "$dockerfile")"
    dock_arm64="$(sed -nE "s/^ARG YQ_CHECKSUM_ARM64=($sha_re)$/\1/p" "$dockerfile")"

    # Guard against an extraction silently matching nothing.
    [ -n "$inst_version" ] && [ -n "$inst_amd64" ] && [ -n "$inst_arm64" ]
    [ -n "$dock_version" ] && [ -n "$dock_amd64" ] && [ -n "$dock_arm64" ]

    [ "$inst_version" = "$dock_version" ] || {
        printf 'yq version drift: install_yq.sh=%s Dockerfile=%s\n' "$inst_version" "$dock_version" >&2
        return 1
    }
    [ "$inst_amd64" = "$dock_amd64" ] || {
        printf 'yq amd64 checksum drift\n' >&2; return 1
    }
    [ "$inst_arm64" = "$dock_arm64" ] || {
        printf 'yq arm64 checksum drift\n' >&2; return 1
    }
}
