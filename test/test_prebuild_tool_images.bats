#!/usr/bin/env bats

# Tests for test/prebuild_tool_images.sh — the concurrent, catalog-driven
# docker-build cache warmer the integration setup runs before the image bats.
# The build itself needs a docker daemon (an integration concern the image bats
# under test/image/ cover); these unit tests pin the catalog-to-directory
# mapping that keeps the prebuilt set from drifting off tools/catalog.json.

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

@test "catalog_image_dirs: derives the tools/ dir from each image ref, skipping adapters" {
    cat > "$TMP_DIR/catalog.json" <<'JSON'
{"tools":{
  "osv":{"delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@sha256:abc"},
  "sbom":{"delivery":"image","image":"ghcr.io/tomhennen/wrangle/syft@sha256:def"},
  "legacy":{"delivery":"adapter"}
}}
JSON
    run catalog_image_dirs "$TMP_DIR/catalog.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"osv"* ]]
    [[ "$output" == *"syft"* ]]
    [[ "$output" != *"legacy"* ]]
}

@test "catalog_image_dirs: an absent catalog yields no output and succeeds" {
    run catalog_image_dirs "$TMP_DIR/missing.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "every catalog image dir maps to a real Dockerfile (drift guard)" {
    local dir
    while IFS= read -r dir; do
        [ -f "$ORIG_DIR/tools/$dir/Dockerfile" ]
    done < <(catalog_image_dirs "$ORIG_DIR/tools/catalog.json")
}
