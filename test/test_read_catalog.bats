#!/usr/bin/env bats

# Tests for lib/read_catalog.sh — the strict, dependency-free reader run.sh uses
# to resolve a tool's curated catalog entry (docs/tool_container_design.md §3.6).

setup() {
    ORIG_DIR="$(pwd)"
    READER="$ORIG_DIR/lib/read_catalog.sh"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/catalog-XXXXXX")"
    CATALOG="$TMP_DIR/catalog.yaml"
    export ORIG_DIR READER TMP_DIR CATALOG

    cat > "$CATALOG" <<'YAML'
# a comment line
tools:
  osv:
    kind: scan
    delivery: image
    image: ghcr.io/tomhennen/wrangle/osv@sha256:abc123
    network: egress          # inline comment after the value
  syft:
    kind: sbom
    delivery: image
    image: ghcr.io/tomhennen/wrangle/syft@sha256:def456
    format: spdx-json
  legacy:
    kind: scan
    delivery: adapter
YAML
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

@test "read_catalog: reads a simple scalar field" {
    run "$READER" "$CATALOG" osv kind
    [ "$status" -eq 0 ]
    [ "$output" = "scan" ]
}

@test "read_catalog: strips an inline comment and surrounding whitespace" {
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
    run "$READER" "$TMP_DIR/none.yaml" osv kind
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "read_catalog: wrong argument count errors" {
    run "$READER" "$CATALOG" osv
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]
}

@test "read_catalog: the shipped catalog resolves osv as a delivery: image scan tool" {
    run "$READER" "$ORIG_DIR/tools/catalog.yaml" osv delivery
    [ "$output" = "image" ]
    run "$READER" "$ORIG_DIR/tools/catalog.yaml" osv kind
    [ "$output" = "scan" ]
    run "$READER" "$ORIG_DIR/tools/catalog.yaml" osv image
    [[ "$output" == ghcr.io/tomhennen/wrangle/osv@sha256:* ]]
    run "$READER" "$ORIG_DIR/tools/catalog.yaml" osv network
    [ "$output" = "egress" ]
}
