#!/usr/bin/env bats

# Tests for lib/merge_catalog.sh — the add-only custom-tools union. The model:
# effective catalog = curated tools ∪ adopter-added tools. A custom tool whose
# name collides with a curated tool is a hard error (no override, no field
# merge); each added tool declares its own capabilities with no inheritance from
# curated, and its image must be outside the wrangle namespace.

setup() {
    ORIG_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    MERGE="$ORIG_DIR/lib/merge_catalog.sh"
    TEST_DIR="$(mktemp -d)"
    DIGEST="sha256:$(printf 'a%.0s' {1..64})"
    DIGEST2="sha256:$(printf 'b%.0s' {1..64})"
    CURATED="$TEST_DIR/curated.json"
    CUSTOM="$TEST_DIR/custom.json"
    cat > "$CURATED" <<JSON
{"tools":{
  "osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@$DIGEST","network":"egress","secret":"github-token"},
  "sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/tomhennen/wrangle/syft@$DIGEST","network":"none"}
}}
JSON
}

teardown() {
    [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

_merge() { run "$MERGE" "$CURATED" "$CUSTOM"; }

@test "merge: a net-new custom tool is unioned in; curated tools survive" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/myorg/my-sbom@$DIGEST"}}}
JSON
    _merge
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools["my-sbom"].image' <<<"$output")" = "ghcr.io/myorg/my-sbom@$DIGEST" ]
    [ "$(jq -r '.tools.sbom.kind' <<<"$output")" = "sbom" ]
    [ "$(jq -r '.tools.osv.kind' <<<"$output")" = "scan" ]
}

@test "merge: a name colliding with a curated tool is REJECTED (add-only, no override)" {
    cat > "$CUSTOM" <<JSON
{"tools":{"osv":{"kind":"scan","delivery":"image","image":"ghcr.io/myorg/osv@$DIGEST2"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"collides with a curated tool"* ]]
    [[ "$output" == *"osv"* ]]
}

@test "merge: an added tool gets exactly the grants it declares (no curated inheritance)" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-scan":{"kind":"scan","delivery":"image","image":"ghcr.io/myorg/s@$DIGEST","network":"egress","secret":"my-token"}}}
JSON
    _merge
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools["my-scan"].network' <<<"$output")" = "egress" ]
    [ "$(jq -r '.tools["my-scan"].secret' <<<"$output")" = "my-token" ]
    # A curated tool the adopter did not touch is unchanged.
    [ "$(jq -r '.tools.osv.secret' <<<"$output")" = "github-token" ]
}

@test "merge: an added tool with no network/secret declares neither" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/myorg/my-sbom@$DIGEST"}}}
JSON
    _merge
    [ "$status" -eq 0 ]
    [ "$(jq '.tools["my-sbom"] | has("network")' <<<"$output")" = "false" ]
    [ "$(jq '.tools["my-sbom"] | has("secret")' <<<"$output")" = "false" ]
}

@test "merge: rejects an invalid tool name" {
    cat > "$CUSTOM" <<JSON
{"tools":{"BadName":{"kind":"sbom","delivery":"image","image":"ghcr.io/x@$DIGEST"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid tool name"* ]]
}

@test "merge: rejects an out-of-allowlist kind" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"exfiltrate","delivery":"image","image":"ghcr.io/x@$DIGEST"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"kind must be one of"* ]]
}

@test "merge: rejects an out-of-allowlist network" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/x@$DIGEST","network":"host"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"network must be one of"* ]]
}

@test "merge: rejects an invalid secret name" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/x@$DIGEST","secret":"BAD_NAME"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid secret name"* ]]
}

@test "merge: rejects a non-digest-pinned image" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/x:latest"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"digest-pinned"* ]]
}

@test "merge: rejects a tool with no image" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"must declare a digest-pinned image"* ]]
}

@test "merge: rejects a tool that is not delivery: image" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","image":"ghcr.io/x@$DIGEST"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"must declare delivery: image"* ]]
}

@test "merge: an off-namespace custom image is allowed (adopter-trusted)" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/myorg/my-sbom@$DIGEST"}}}
JSON
    _merge
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools["my-sbom"].image' <<<"$output")" = "ghcr.io/myorg/my-sbom@$DIGEST" ]
}

@test "merge: rejects a custom image in the wrangle namespace (no borrowing a VSA identity)" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@$DIGEST"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not be in the wrangle namespace"* ]]
}

@test "merge: rejects a wrangle-namespace image via the registry-port form" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-osv":{"kind":"scan","delivery":"image","image":"ghcr.io:443/tomhennen/wrangle/osv@$DIGEST"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not be in the wrangle namespace"* ]]
}

@test "merge: rejects an array-valued tool entry (clean error, not a raw jq failure)" {
    printf '{"tools":{"t":["x"]}}' > "$CUSTOM"
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"every tool entry must be an object"* ]]
}

@test "merge: preserves curated top-level siblings such as _comment" {
    printf '{"_comment":"keep me","tools":{"osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@%s"}}}' "$DIGEST" > "$CURATED"
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/myorg/my-sbom@$DIGEST"}}}
JSON
    _merge
    [ "$status" -eq 0 ]
    [ "$(jq -r '._comment' <<<"$output")" = "keep me" ]
}

@test "merge: rejects a non-object tools envelope" {
    printf '{"tools":[]}' > "$CUSTOM"
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid JSON catalog"* ]]
}

@test "merge: rejects malformed JSON" {
    printf 'not json{' > "$CUSTOM"
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid JSON catalog"* ]]
}

@test "merge: tolerates a missing curated catalog (adopter-only tools)" {
    cat > "$CUSTOM" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/myorg/my-sbom@$DIGEST"}}}
JSON
    run "$MERGE" "$TEST_DIR/does-not-exist.json" "$CUSTOM"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools["my-sbom"].kind' <<<"$output")" = "sbom" ]
}
