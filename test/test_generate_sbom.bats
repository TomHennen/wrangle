#!/usr/bin/env bats

# Tests for lib/generate_sbom.sh — the build-composite SBOM dispatch that runs a
# curated container SBOM tool through run.sh and lifts its <tool>/ outputs up to
# the metadata-dir root the attest engine discovers.
#
# Drives run.sh's image dispatch via a mock `docker` on PATH, so the relocation
# and fail-closed glue are exercised without a real container.

DIGEST="sha256:$(printf '0%.0s' {1..64})"

setup() {
    ORIG_DIR="$(pwd)"
    TEST_DIR="$(mktemp -d)"
    export ORIG_DIR TEST_DIR
    SRC="$TEST_DIR/src"
    META="$TEST_DIR/meta"
    TOOLS="$TEST_DIR/tools"
    BIN_DIR="$TEST_DIR/bin"
    MOCK_SPEC="$TEST_DIR/spec"
    mkdir -p "$SRC" "$TOOLS" "$BIN_DIR" "$MOCK_SPEC"
    export MOCK_SPEC
    printf 'source\n' > "$SRC/file.txt"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }

    export WRANGLE_VERIFY_TOOL_IMAGES=0

    # Mock `docker`: derive the tool from the /output mount and replay
    # $MOCK_SPEC/<tool>.{sbom,exit} into it — the sbom-kind image's behavior.
    cat > "$BIN_DIR/docker" <<'DOCKER'
#!/usr/bin/env bash
set -u
out="" ; prev=""
for a in "$@"; do
    [[ "$prev" == "-v" && "$a" == *:/output ]] && out="${a%:/output}"
    prev="$a"
done
[[ -n "$out" ]] || { printf 'mock docker: no /output mount\n' >&2; exit 96; }
tool="$(basename "$out")"
spec="$MOCK_SPEC/$tool"
[[ -f "$spec.sbom" ]] && cp "$spec.sbom" "$out/sbom.spdx.json"
[[ -f "$spec.exit" ]] && exit "$(cat "$spec.exit")"
exit 0
DOCKER
    chmod +x "$BIN_DIR/docker"
    export PATH="$BIN_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# _sbom_tool <tool> — declare <tool> as a kind: sbom delivery: image tool.
_sbom_tool() {
    local cat="$TOOLS/catalog.json" tmp
    [[ -f "$cat" ]] || printf '{"tools":{}}' > "$cat"
    tmp="$(mktemp)"
    jq --arg t "$1" --arg img "ghcr.io/tomhennen/wrangle/$1@$DIGEST" \
        '.tools[$t] = {kind:"sbom", delivery:"image", image:$img}' "$cat" > "$tmp"
    mv "$tmp" "$cat"
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
    _sbom_tool stubsbom
    printf '{"spdxVersion":"SPDX-2.3"}\n' > "$MOCK_SPEC/stubsbom.sbom"
    printf '0' > "$MOCK_SPEC/stubsbom.exit"
    _run_gen "$SRC" "$META" stubsbom
    [ "$status" -eq 0 ]
    [ -f "$META/sbom.spdx.json" ]
    [ -f "$META/wrangle_attestation_metadata.json" ]
    # The per-tool subdir run.sh wrote into is emptied and removed.
    [ ! -d "$META/stubsbom" ]
}

@test "generate_sbom: manifest names the SPDX predicate and result file" {
    _sbom_tool stubsbom
    printf '{"spdxVersion":"SPDX-2.3"}\n' > "$MOCK_SPEC/stubsbom.sbom"
    printf '0' > "$MOCK_SPEC/stubsbom.exit"
    _run_gen "$SRC" "$META" stubsbom
    [ "$status" -eq 0 ]
    [ "$(jq -r '."predicate-type"' "$META/wrangle_attestation_metadata.json")" = "https://spdx.dev/Document" ]
    [ "$(jq -r '."result-file"' "$META/wrangle_attestation_metadata.json")" = "sbom.spdx.json" ]
}

@test "generate_sbom: defaults the tool to the sbom slot when none is given" {
    # No tool arg -> the ${3:-sbom} default; the catalog's sbom entry dispatches
    # via the image path (image tools need no local directory).
    _sbom_tool sbom
    printf '{"spdxVersion":"SPDX-2.3"}\n' > "$MOCK_SPEC/sbom.sbom"
    printf '0' > "$MOCK_SPEC/sbom.exit"
    _run_gen "$SRC" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/sbom.spdx.json" ]
    [ ! -d "$META/sbom" ]
}

@test "generate_sbom: fails closed when the dispatched tool errors" {
    # A tool that produces no SBOM and exits 2 (the shape of a failed VSA gate /
    # tool error). run.sh returns 2; generate_sbom must propagate, not relocate.
    _sbom_tool stubsbom
    printf '2' > "$MOCK_SPEC/stubsbom.exit"
    _run_gen "$SRC" "$META" stubsbom
    [ "$status" -ne 0 ]
    [ ! -f "$META/sbom.spdx.json" ]
}
