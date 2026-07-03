#!/usr/bin/env bats

# Tests for lib/generate_sbom.sh — the build-composite SBOM dispatch that runs a
# curated container SBOM tool through run.sh and lifts its <tool>/ outputs up to
# the metadata-dir root the attest engine discovers.
#
# Drives run.sh's adapter path via a stub tool (WRANGLE_TOOLS_DIR), so the
# relocation and fail-closed glue are exercised without docker.

setup() {
    ORIG_DIR="$(pwd)"
    TEST_DIR="$(mktemp -d)"
    export ORIG_DIR TEST_DIR
    SRC="$TEST_DIR/src"
    META="$TEST_DIR/meta"
    TOOLS="$TEST_DIR/tools"
    mkdir -p "$SRC" "$TOOLS/stubsbom"
    printf 'source\n' > "$SRC/file.txt"

    # A stub sbom-kind adapter: writes sbom.spdx.json, exit 0. No catalog, so
    # run.sh takes the adapter path (no docker); its shared post-run step writes
    # the spdx attest manifest just as the image path would.
    cat > "$TOOLS/stubsbom/adapter.sh" <<'ADAPT'
#!/bin/bash
set -euo pipefail
printf '{"spdxVersion":"SPDX-2.3"}\n' > "$2/sbom.spdx.json"
exit 0
ADAPT
    chmod +x "$TOOLS/stubsbom/adapter.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

_run_gen() {
    WRANGLE_TOOLS_DIR="$TOOLS" run "$ORIG_DIR/lib/generate_sbom.sh" "$@"
}

@test "generate_sbom: rejects wrong argument count" {
    _run_gen "$SRC"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "generate_sbom: lifts SBOM + manifest to the metadata-dir root" {
    _run_gen "$SRC" "$META" stubsbom
    [ "$status" -eq 0 ]
    [ -f "$META/sbom.spdx.json" ]
    [ -f "$META/wrangle_attestation_metadata.json" ]
    # The per-tool subdir run.sh wrote into is emptied and removed.
    [ ! -d "$META/stubsbom" ]
}

@test "generate_sbom: manifest names the SPDX predicate and result file" {
    _run_gen "$SRC" "$META" stubsbom
    [ "$status" -eq 0 ]
    [ "$(jq -r '."predicate-type"' "$META/wrangle_attestation_metadata.json")" = "https://spdx.dev/Document" ]
    [ "$(jq -r '."result-file"' "$META/wrangle_attestation_metadata.json")" = "sbom.spdx.json" ]
}

@test "generate_sbom: defaults the tool to the sbom slot when none is given" {
    # No catalog in the mock tools dir, so a stub sbom/ dir dispatches via the
    # adapter path — exercising the ${3:-sbom} default without docker.
    cp -r "$TOOLS/stubsbom" "$TOOLS/sbom"
    _run_gen "$SRC" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/sbom.spdx.json" ]
    [ ! -d "$META/sbom" ]
}

@test "generate_sbom: fails closed when the dispatched tool errors" {
    # A stub that produces no SBOM and exits 2 (the shape of a failed VSA gate /
    # tool error). run.sh returns 2; generate_sbom must propagate, not relocate.
    cat > "$TOOLS/stubsbom/adapter.sh" <<'ADAPT'
#!/bin/bash
exit 2
ADAPT
    chmod +x "$TOOLS/stubsbom/adapter.sh"
    _run_gen "$SRC" "$META" stubsbom
    [ "$status" -ne 0 ]
    [ ! -f "$META/sbom.spdx.json" ]
}
