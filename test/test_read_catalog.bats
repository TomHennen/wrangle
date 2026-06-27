#!/usr/bin/env bats

# Tests for lib/read_catalog.sh — the jq-backed reader run.sh uses to resolve a
# tool's curated catalog entry (docs/tool_container_design.md §3.6).

load "lib/bats_helpers"

setup() {
    command -v jq >/dev/null 2>&1 || skip_or_fail "jq not on PATH"
    ORIG_DIR="$(pwd)"
    READER="$ORIG_DIR/lib/read_catalog.sh"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/catalog-XXXXXX")"
    CATALOG="$TMP_DIR/catalog.json"
    export ORIG_DIR READER TMP_DIR CATALOG

    cat > "$CATALOG" <<'JSON'
{
  "tools": {
    "osv": {
      "kind": "scan",
      "delivery": "image",
      "image": "ghcr.io/tomhennen/wrangle/osv@sha256:abc123",
      "network": "egress"
    },
    "syft": {
      "kind": "sbom",
      "delivery": "image",
      "image": "ghcr.io/tomhennen/wrangle/syft@sha256:def456",
      "format": "spdx-json"
    },
    "legacy": {
      "kind": "scan",
      "delivery": "adapter"
    }
  }
}
JSON
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

@test "read_catalog: reads a simple scalar field" {
    run "$READER" "$CATALOG" osv kind
    [ "$status" -eq 0 ]
    [ "$output" = "scan" ]
}

@test "read_catalog: reads a value with no surrounding decoration" {
    run "$READER" "$CATALOG" osv network
    [ "$status" -eq 0 ]
    [ "$output" = "egress" ]
}

@test "read_catalog: reads the image digest verbatim" {
    run "$READER" "$CATALOG" osv image
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/tomhennen/wrangle/osv@sha256:abc123" ]
}

@test "read_catalog: a field of a later entry is not attributed to an earlier one" {
    run "$READER" "$CATALOG" osv format
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run "$READER" "$CATALOG" syft format
    [ "$output" = "spdx-json" ]
}

@test "read_catalog: an absent tool yields nothing, exit 0" {
    run "$READER" "$CATALOG" nonexistent image
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "read_catalog: an absent field yields nothing, exit 0" {
    run "$READER" "$CATALOG" legacy image
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "read_catalog: delivery: adapter is read as adapter" {
    run "$READER" "$CATALOG" legacy delivery
    [ "$output" = "adapter" ]
}

@test "read_catalog: a missing catalog file yields nothing, exit 0" {
    run "$READER" "$TMP_DIR/none.json" osv kind
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "read_catalog: a malformed catalog fails closed (nonzero exit)" {
    printf 'not valid json' > "$TMP_DIR/broken.json"
    run "$READER" "$TMP_DIR/broken.json" osv kind
    [ "$status" -ne 0 ]
}

@test "read_catalog: wrong argument count errors" {
    run "$READER" "$CATALOG" osv
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]
}

@test "read_catalog: the shipped catalog resolves osv as a delivery: image scan tool" {
    run "$READER" "$ORIG_DIR/tools/catalog.json" osv delivery
    [ "$output" = "image" ]
    run "$READER" "$ORIG_DIR/tools/catalog.json" osv kind
    [ "$output" = "scan" ]
    run "$READER" "$ORIG_DIR/tools/catalog.json" osv image
    [[ "$output" == ghcr.io/tomhennen/wrangle/osv@sha256:* ]]
    run "$READER" "$ORIG_DIR/tools/catalog.json" osv network
    [ "$output" = "egress" ]
}

@test "read_catalog: the shipped catalog resolves zizmor as a digest-pinned image with egress + github-token" {
    run "$READER" "$ORIG_DIR/tools/catalog.json" zizmor delivery
    [ "$output" = "image" ]
    run "$READER" "$ORIG_DIR/tools/catalog.json" zizmor kind
    [ "$output" = "scan" ]
    run "$READER" "$ORIG_DIR/tools/catalog.json" zizmor image
    [[ "$output" == ghcr.io/tomhennen/wrangle/zizmor@sha256:[0-9a-f]* ]]
    run "$READER" "$ORIG_DIR/tools/catalog.json" zizmor network
    [ "$output" = "egress" ]
    run "$READER" "$ORIG_DIR/tools/catalog.json" zizmor secret
    [ "$output" = "github-token" ]
}

@test "read_catalog: the shipped catalog resolves wrangle-lint as a digest-pinned image, no network or secret" {
    run "$READER" "$ORIG_DIR/tools/catalog.json" wrangle-lint delivery
    [ "$output" = "image" ]
    run "$READER" "$ORIG_DIR/tools/catalog.json" wrangle-lint kind
    [ "$output" = "scan" ]
    run "$READER" "$ORIG_DIR/tools/catalog.json" wrangle-lint image
    [[ "$output" == ghcr.io/tomhennen/wrangle/wrangle-lint@sha256:[0-9a-f]* ]]
    run "$READER" "$ORIG_DIR/tools/catalog.json" wrangle-lint network
    [ "$output" = "none" ]
    run "$READER" "$ORIG_DIR/tools/catalog.json" wrangle-lint secret
    [ -z "$output" ]
}
