#!/bin/bash
set -euo pipefail
set -f

# test/lib/image_test_harness.sh — helpers for testing a tool container
# image against the wrangle adapter contract:
#   docker run <image> /src /output  ->  writes /output/output.sarif,
#   exits 0 (clean) / 1 (findings) / 2 (tool error); writes nothing outside
#   /output; runs as the caller's UID so output is consumable.
#
# Source after test/lib/bats_helpers (for skip_or_fail). Intended for per-tool
# `test_image.bats` files; gate every test on `wrangle_require_docker`.

# Fail in CI / skip locally when docker isn't usable.
wrangle_require_docker() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        skip_or_fail "docker not available (needed to run tool images)"
    fi
}

# wrangle_prebuilt_image <tag> — true when build_shell.yml's image-cache
# restored <tag>, letting a setup_file skip its build.
wrangle_prebuilt_image() {
    [[ "${WRANGLE_TOOL_IMAGES_PREBUILT:-}" == "1" ]] \
        && docker image inspect "$1" >/dev/null 2>&1
}

# wrangle_image_scan <image> <src_dir> <out_dir> [network]
# Runs the image under the contract sandbox (read-only src, writable output,
# non-root as the caller, network off by default) and returns its exit code.
wrangle_image_scan() {
    local image="$1" src="$2" out="$3" network="${4:-none}"
    docker run --rm --network "$network" -u "$(id -u):$(id -g)" \
        -v "$src":/src:ro -v "$out":/output "$image" /src /output
}

# wrangle_assert_sarif <out_dir> — output.sarif exists and is valid JSON.
wrangle_assert_sarif() {
    local out="$1"
    if [[ ! -f "$out/output.sarif" ]]; then
        printf 'contract: missing %s/output.sarif\n' "$out" >&2
        return 1
    fi
    if ! jq empty "$out/output.sarif" 2>/dev/null; then
        printf 'contract: %s/output.sarif is not valid JSON\n' "$out" >&2
        return 1
    fi
}

# wrangle_assert_src_unchanged <src_dir> <expected_file_count>
# The contract forbids writes outside /output; src is mounted read-only, so a
# tool that tries to write there fails. This double-checks src is untouched.
wrangle_assert_src_unchanged() {
    local src="$1" expected="$2" actual
    actual="$(find "$src" -type f | wc -l | tr -d ' ')"
    if [[ "$actual" != "$expected" ]]; then
        printf 'contract: src tree changed (%s files, expected %s)\n' "$actual" "$expected" >&2
        return 1
    fi
}
