#!/usr/bin/env bats

# Unit tests for tools/check_catalog.sh — the static, network-free catalog
# validator. Hermetic: each test writes a fixture catalog and points the script
# at it via $WRANGLE_CATALOG.

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/check_catalog.sh"
    CATALOG="$BATS_TEST_TMPDIR/catalog.json"
    export WRANGLE_CATALOG="$CATALOG"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }
}

write_catalog() { printf '%s\n' "$1" > "$CATALOG"; }

@test "check_catalog: valid curated catalog passes" {
    write_catalog '{"tools":{"osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@sha256:'"$(printf 'a%.0s' {1..64})"'","network":"egress"}}}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "check_catalog: mutable tag (no digest) fails" {
    write_catalog '{"tools":{"osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv:latest"}}}'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"osv"* ]]
}

@test "check_catalog: off-namespace ghcr image fails" {
    write_catalog '{"tools":{"osv":{"kind":"scan","delivery":"image","image":"ghcr.io/someoneelse/osv@sha256:'"$(printf 'a%.0s' {1..64})"'"}}}'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"curated namespace"* ]]
}

@test "check_catalog: missing kind fails" {
    write_catalog '{"tools":{"osv":{"delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@sha256:'"$(printf 'a%.0s' {1..64})"'"}}}'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing kind"* ]]
}

@test "check_catalog: bad network value fails" {
    write_catalog '{"tools":{"osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@sha256:'"$(printf 'a%.0s' {1..64})"'","network":"full"}}}'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid network"* ]]
}

@test "check_catalog: bad secret name fails" {
    write_catalog '{"tools":{"osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@sha256:'"$(printf 'a%.0s' {1..64})"'","secret":"Bad_Name"}}}'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid secret"* ]]
}

@test "check_catalog: malformed JSON fails with exit 1" {
    printf '{ not json\n' > "$CATALOG"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not valid JSON"* ]]
}

@test "check_catalog: non-ghcr digest-pinned image passes (fallback)" {
    write_catalog '{"tools":{"osv":{"kind":"scan","delivery":"image","image":"registry.example.com/team/osv@sha256:'"$(printf 'a%.0s' {1..64})"'"}}}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "check_catalog: extra argument is a usage error (exit 2)" {
    write_catalog '{"tools":{}}'
    run "$SCRIPT" unexpected
    [ "$status" -eq 2 ]
}
