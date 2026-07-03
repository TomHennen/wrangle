#!/usr/bin/env bats

# Tests for lib/merge_catalog.sh — the adopter tool-overrides merge. The security
# rule under test: an override entry's non-capability fields deep-merge over the
# curated entry, but network and secret hold ONLY when the override restates
# them, else they reset closed (docs/tool_container_design.md §3.7).

setup() {
    ORIG_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    MERGE="$ORIG_DIR/lib/merge_catalog.sh"
    TEST_DIR="$(mktemp -d)"
    DIGEST="sha256:$(printf 'a%.0s' {1..64})"
    DIGEST2="sha256:$(printf 'b%.0s' {1..64})"
    CURATED="$TEST_DIR/curated.json"
    OVERRIDE="$TEST_DIR/override.json"
    cat > "$CURATED" <<JSON
{"tools":{
  "osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@$DIGEST","network":"egress","secret":"github-token"},
  "syft":{"kind":"sbom","delivery":"image","image":"ghcr.io/tomhennen/wrangle/syft@$DIGEST","network":"none"}
}}
JSON
}

teardown() {
    [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

_merge() { run "$MERGE" "$CURATED" "$OVERRIDE"; }

@test "merge: override of a curated tool image only RESETS network and secret closed" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"osv":{"image":"ghcr.io/myorg/osv@$DIGEST2"}}}
JSON
    _merge
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools.osv.image' <<<"$output")" = "ghcr.io/myorg/osv@$DIGEST2" ]
    [ "$(jq -r '.tools.osv.kind' <<<"$output")" = "scan" ]
    [ "$(jq '.tools.osv | has("network")' <<<"$output")" = "false" ]
    [ "$(jq '.tools.osv | has("secret")' <<<"$output")" = "false" ]
}

@test "merge: override restating network keeps it; an unrestated secret still resets" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"osv":{"image":"ghcr.io/myorg/osv@$DIGEST2","network":"egress"}}}
JSON
    _merge
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools.osv.network' <<<"$output")" = "egress" ]
    [ "$(jq '.tools.osv | has("secret")' <<<"$output")" = "false" ]
}

@test "merge: a new BYO tool is added with its declared fields" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/myorg/my-sbom@$DIGEST"}}}
JSON
    _merge
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools["my-sbom"].kind' <<<"$output")" = "sbom" ]
    [ "$(jq -r '.tools["my-sbom"].image' <<<"$output")" = "ghcr.io/myorg/my-sbom@$DIGEST" ]
    # Curated tools survive the merge.
    [ "$(jq -r '.tools.syft.kind' <<<"$output")" = "sbom" ]
}

@test "merge: curated-namespace override image is allowed (VSA gate handles trust)" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"osv":{"image":"ghcr.io/tomhennen/wrangle/osv@$DIGEST2"}}}
JSON
    _merge
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools.osv.image' <<<"$output")" = "ghcr.io/tomhennen/wrangle/osv@$DIGEST2" ]
}

@test "merge: rejects an invalid tool name" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"BadName":{"kind":"sbom","delivery":"image","image":"ghcr.io/x@$DIGEST"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid tool name"* ]]
}

@test "merge: rejects an out-of-allowlist kind" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"my-sbom":{"kind":"exfiltrate","delivery":"image","image":"ghcr.io/x@$DIGEST"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"kind must be one of"* ]]
}

@test "merge: rejects an out-of-allowlist network" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/x@$DIGEST","network":"host"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"network must be one of"* ]]
}

@test "merge: rejects an invalid secret name" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/x@$DIGEST","secret":"BAD_NAME"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"secret must match"* ]]
}

@test "merge: rejects a non-digest-pinned image" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/x:latest"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"digest-pinned"* ]]
}

@test "merge: rejects a new tool with no image" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"new-tool":{"kind":"sbom","delivery":"image"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"must declare a digest-pinned image"* ]]
}

@test "merge: rejects a new tool that is not delivery: image" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"new-tool":{"kind":"sbom","image":"ghcr.io/x@$DIGEST"}}}
JSON
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"must declare delivery: image"* ]]
}

@test "merge: rejects a non-object tools envelope" {
    printf '{"tools":[]}' > "$OVERRIDE"
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"\"tools\" must be an object"* ]]
}

@test "merge: rejects malformed JSON" {
    printf 'not json{' > "$OVERRIDE"
    _merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid JSON"* ]]
}

@test "merge: tolerates a missing curated catalog (adopter-only tools)" {
    cat > "$OVERRIDE" <<JSON
{"tools":{"my-sbom":{"kind":"sbom","delivery":"image","image":"ghcr.io/myorg/my-sbom@$DIGEST"}}}
JSON
    run "$MERGE" "$TEST_DIR/does-not-exist.json" "$OVERRIDE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools["my-sbom"].kind' <<<"$output")" = "sbom" ]
}
