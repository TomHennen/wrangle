#!/usr/bin/env bats

# Tests for test/prebuild_tool_images.sh — the concurrent, catalog-driven
# docker-build cache warmer the integration setup runs before the image bats.
# The build itself needs a docker daemon (an integration concern the image bats
# under test/image/ cover); these unit tests pin the catalog-to-directory and
# directory-to-tag mappings that keep the prebuilt set from drifting off
# tools/catalog.json and the tags the bats files build.

load "lib/bats_helpers"

setup() {
    command -v jq >/dev/null 2>&1 || skip_or_fail "jq not on PATH"
    ORIG_DIR="$(pwd)"
    SCRIPT="$ORIG_DIR/test/prebuild_tool_images.sh"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prebuild-XXXXXX")"
    export ORIG_DIR SCRIPT TMP_DIR
    # shellcheck source=../test/prebuild_tool_images.sh
    source "$SCRIPT"
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

@test "catalog_image_dirs: selects every entry naming an image, delivery or not" {
    # An image-bearing entry is selected regardless of its delivery field —
    # the check_catalog.sh posture.
    cat > "$TMP_DIR/catalog.json" <<'JSON'
{"tools":{
  "osv":{"delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@sha256:abc"},
  "sbom":{"delivery":"image","image":"ghcr.io/tomhennen/wrangle/syft@sha256:def"},
  "attest-toolbox":{"kind":"attest","image":"ghcr.io/tomhennen/wrangle/attest-toolbox@sha256:123"},
  "legacy":{"delivery":"adapter"}
}}
JSON
    run catalog_image_dirs "$TMP_DIR/catalog.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"osv"* ]]
    [[ "$output" == *"syft"* ]]
    [[ "$output" == *"attest-toolbox"* ]]
    [[ "$output" != *"legacy"* ]]
}

@test "catalog_image_dirs: an absent catalog yields no output and succeeds" {
    run catalog_image_dirs "$TMP_DIR/missing.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "prebuild_image_tag: maps dirs to the tags the image bats build" {
    [ "$(prebuild_image_tag osv)" = "wrangle-osv:test" ]
    [ "$(prebuild_image_tag attest-toolbox)" = "wrangle-attest-toolbox:test" ]
    [ "$(prebuild_image_tag wrangle-lint)" = "wrangle-lint:test" ]
}

@test "list: prints one bats tag per catalog image" {
    run "$SCRIPT" list
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    local line
    while IFS= read -r line; do
        [[ "$line" == wrangle-*:test ]]
    done <<< "$output"
    [[ "$output" == *"wrangle-attest-toolbox:test"* ]]
}

@test "real catalog: selection is non-empty and covers exactly the tool Dockerfiles" {
    local selected dockerfiles
    selected="$(catalog_image_dirs "$ORIG_DIR/tools/catalog.json" | sort -u)"
    [ -n "$selected" ]
    dockerfiles="$( (cd "$ORIG_DIR/tools" && set +f && ls -d ./*/Dockerfile) \
        | xargs -n1 dirname | xargs -n1 basename | sort -u)"
    [ "$selected" = "$dockerfiles" ]
}
