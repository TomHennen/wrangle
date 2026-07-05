#!/usr/bin/env bats

# Unit tests for tools/bump_catalog_digest.sh — the one-command catalog digest
# fix. Hermetic: each test operates on a fixture catalog via $WRANGLE_CATALOG.

DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/bump_catalog_digest.sh"
    CATALOG="$BATS_TEST_TMPDIR/catalog.json"
    export WRANGLE_CATALOG="$CATALOG"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }
    printf '%s\n' \
        '{"tools":{"osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@'"$DIGEST_A"'","network":"egress"}}}' \
        > "$CATALOG"
}

image_of() { jq -r '.tools.osv.image' "$CATALOG"; }

@test "bump_catalog_digest: happy path repoints to new digest, keeps namespace" {
    run "$SCRIPT" osv "$DIGEST_B"
    [ "$status" -eq 0 ]
    [ "$(image_of)" = "ghcr.io/tomhennen/wrangle/osv@$DIGEST_B" ]
    # Untouched fields survive.
    [ "$(jq -r '.tools.osv.network' "$CATALOG")" = "egress" ]
}

@test "bump_catalog_digest: bad digest is rejected (exit 2)" {
    run "$SCRIPT" osv "sha256:nothex"
    [ "$status" -eq 2 ]
    [ "$(image_of)" = "ghcr.io/tomhennen/wrangle/osv@$DIGEST_A" ]
}

@test "bump_catalog_digest: unknown tool is rejected (exit 2)" {
    run "$SCRIPT" nosuchtool "$DIGEST_B"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown tool"* ]]
}

@test "bump_catalog_digest: non-image tool is rejected (exit 2)" {
    printf '%s\n' '{"tools":{"foo":{"kind":"scan","delivery":"adapter"}}}' > "$CATALOG"
    run "$SCRIPT" foo "$DIGEST_B"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not an image-delivery tool"* ]]
}

@test "bump_catalog_digest: idempotent re-run leaves the file byte-identical" {
    run "$SCRIPT" osv "$DIGEST_B"
    [ "$status" -eq 0 ]
    local after_first; after_first="$(cat "$CATALOG")"
    run "$SCRIPT" osv "$DIGEST_B"
    [ "$status" -eq 0 ]
    [ "$(cat "$CATALOG")" = "$after_first" ]
}

@test "bump_catalog_digest: wrong arg count is a usage error (exit 2)" {
    run "$SCRIPT" osv
    [ "$status" -eq 2 ]
}
