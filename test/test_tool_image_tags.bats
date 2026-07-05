#!/usr/bin/env bats

# Tests for test/tool_image_tags.sh — the catalog-derived tag list the
# integration setup registers for build_shell.yml's image-cache steps. These
# pin the catalog-to-directory and directory-to-tag mappings so the cached set
# can't drift off tools/catalog.json or the tags the test/image bats build.

load "lib/bats_helpers"

setup() {
    command -v jq >/dev/null 2>&1 || skip_or_fail "jq not on PATH"
    ORIG_DIR="$(pwd)"
    SCRIPT="$ORIG_DIR/test/tool_image_tags.sh"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tool-tags-XXXXXX")"
    export ORIG_DIR SCRIPT TMP_DIR
    # shellcheck source=../test/tool_image_tags.sh
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

@test "tool_image_tag: maps dirs to the tags the image bats build" {
    [ "$(tool_image_tag osv)" = "wrangle-osv:test" ]
    [ "$(tool_image_tag attest-toolbox)" = "wrangle-attest-toolbox:test" ]
    [ "$(tool_image_tag wrangle-lint)" = "wrangle-lint:test" ]
}

@test "real catalog: selection is non-empty and covers exactly the tool Dockerfiles" {
    local selected dockerfiles
    selected="$(catalog_image_dirs "$ORIG_DIR/tools/catalog.json" | sort -u)"
    [ -n "$selected" ]
    dockerfiles="$( (cd "$ORIG_DIR/tools" && set +f && ls -d ./*/Dockerfile) \
        | xargs -n1 dirname | xargs -n1 basename | sort -u)"
    [ "$selected" = "$dockerfiles" ]
}

@test "real catalog: every listed tag is the -t tag some image bats builds" {
    local tag
    while IFS= read -r tag; do
        grep -rqF -- "-t $tag" "$ORIG_DIR/test/image/"
    done < <("$SCRIPT")
}

@test "test/image: every wrangle-* build tag is listed (or the contract mock)" {
    local listed tag
    listed="$("$SCRIPT")"
    while IFS= read -r tag; do
        # wrangle-mock-tool:test is the contract fixture, not a catalog tool.
        [[ "$tag" == "wrangle-mock-tool:test" ]] && continue
        [[ "$listed" == *"$tag"* ]]
    done < <(grep -rhoE -- '-t wrangle-[a-z-]+:[a-z]+' "$ORIG_DIR"/test/image/*.bats \
        | sed 's/^-t //' | sort -u)
}
