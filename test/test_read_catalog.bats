#!/usr/bin/env bats

# Tests for lib/read_catalog.sh — the strict, dependency-free reader run.sh uses
# to resolve a tool's curated catalog entry (docs/tool_container_design.md §3.6).

load "lib/bats_helpers"

# Resolve a python3 that can import PyYAML, mirroring lint.sh: prefer the pinned
# wrangle-workflow-lint venv the test image builds, else a system python3 that
# already has yaml. Echoes the interpreter, or nothing if none is reachable.
yaml_python() {
    local venv="/opt/wrangle-workflow-lint/bin/python3"
    if [[ -x "$venv" ]]; then
        printf '%s' "$venv"
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        printf 'python3'
    fi
}

setup() {
    ORIG_DIR="$(pwd)"
    READER="$ORIG_DIR/lib/read_catalog.sh"
    VALIDATOR="$ORIG_DIR/test/validate_catalog.py"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/catalog-XXXXXX")"
    CATALOG="$TMP_DIR/catalog.yaml"
    export ORIG_DIR READER VALIDATOR TMP_DIR CATALOG

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

# --- Validation against a real YAML parser (CI/dev-time, see validate_catalog.py).
# Pinned to the committed catalog so the hand-rolled scanner can't silently
# diverge from real YAML or be fed a shape it would mishandle.

@test "read_catalog: every field of the shipped catalog matches a real YAML parser" {
    py="$(yaml_python)"
    [[ -n "$py" ]] || skip_or_fail "no python3 with PyYAML"
    run "$py" "$VALIDATOR" diff "$ORIG_DIR/tools/catalog.yaml" "$READER"
    [ "$status" -eq 0 ] || printf '%s\n' "$output" >&2
    [ "$status" -eq 0 ]
}

@test "read_catalog: the shipped catalog conforms to the scanner's strict grammar" {
    py="$(yaml_python)"
    [[ -n "$py" ]] || skip_or_fail "no python3 with PyYAML"
    run "$py" "$VALIDATOR" shape "$ORIG_DIR/tools/catalog.yaml"
    [ "$status" -eq 0 ] || printf '%s\n' "$output" >&2
    [ "$status" -eq 0 ]
}

@test "read_catalog: the differential check has teeth — a wrong scanner fails it" {
    py="$(yaml_python)"
    [[ -n "$py" ]] || skip_or_fail "no python3 with PyYAML"
    # A scanner that mangles every value (uppercases it) must be caught.
    cat > "$TMP_DIR/bad_reader.sh" <<EOF
#!/bin/bash
"$READER" "\$@" | tr '[:lower:]' '[:upper:]'
EOF
    chmod +x "$TMP_DIR/bad_reader.sh"
    run "$py" "$VALIDATOR" diff "$ORIG_DIR/tools/catalog.yaml" "$TMP_DIR/bad_reader.sh"
    [ "$status" -eq 1 ]
}

@test "read_catalog: the shape check rejects a nested/flow-style catalog" {
    py="$(yaml_python)"
    [[ -n "$py" ]] || skip_or_fail "no python3 with PyYAML"
    cat > "$CATALOG" <<'YAML'
tools:
  osv:
    kind: scan
    network: { mode: egress, hosts: [osv.dev] }
YAML
    run "$py" "$VALIDATOR" shape "$CATALOG"
    [ "$status" -eq 1 ]
}
