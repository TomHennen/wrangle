#!/usr/bin/env bats

# Tests for lib/write_scan_manifest.sh — the generic scan/v1 manifest producer.
# result and tool.version are derived from the SARIF, so the manifest can never
# disagree with the findings gate (which reads the same results count).

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../lib" && pwd)/write_scan_manifest.sh"
    TEST_DIR="$(mktemp -d)"
    SARIF="$TEST_DIR/osv/output.sarif"
    mkdir -p "$TEST_DIR/osv"
}

teardown() {
    rm -rf "$TEST_DIR"
}

write_sarif() {
    # $1 = results JSON array body, $2 = version
    cat > "$SARIF" <<EOF
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"osv-scanner","version":"$2"}},"results":[$1]}]}
EOF
}

@test "write_scan_manifest: findings SARIF yields result=findings + scan/v1 schema" {
    write_sarif '{"ruleId":"CVE-1"}' "2.3.8"
    run "$SCRIPT" osv-scanner "$SARIF"
    [[ "$status" -eq 0 ]]
    run jq -r '."predicate-type"' "$TEST_DIR/osv/wrangle_attestation_metadata.json"
    [[ "$output" == "https://github.com/TomHennen/wrangle/attestation/scan/v1" ]]
    run jq -r '."result-file"' "$TEST_DIR/osv/wrangle_attestation_metadata.json"
    [[ "$output" == "output.sarif" ]]
    run jq -r '.tool.name' "$TEST_DIR/osv/wrangle_attestation_metadata.json"
    [[ "$output" == "osv-scanner" ]]
    run jq -r '.tool.version' "$TEST_DIR/osv/wrangle_attestation_metadata.json"
    [[ "$output" == "2.3.8" ]]
    run jq -r '.result' "$TEST_DIR/osv/wrangle_attestation_metadata.json"
    [[ "$output" == "findings" ]]
}

@test "write_scan_manifest: empty results yields result=clean" {
    write_sarif '' "2.3.8"
    run "$SCRIPT" osv-scanner "$SARIF"
    [[ "$status" -eq 0 ]]
    run jq -r '.result' "$TEST_DIR/osv/wrangle_attestation_metadata.json"
    [[ "$output" == "clean" ]]
}

@test "write_scan_manifest: missing driver version yields empty string, not null" {
    cat > "$SARIF" <<'EOF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"osv-scanner"}},"results":[]}]}
EOF
    run "$SCRIPT" osv-scanner "$SARIF"
    [[ "$status" -eq 0 ]]
    run jq -r '.tool.version' "$TEST_DIR/osv/wrangle_attestation_metadata.json"
    [[ "$output" == "" ]]
}

@test "write_scan_manifest: invalid SARIF fails closed (exit 2, no manifest)" {
    printf 'not json' > "$SARIF"
    run "$SCRIPT" osv-scanner "$SARIF"
    [[ "$status" -eq 2 ]]
    [[ ! -f "$TEST_DIR/osv/wrangle_attestation_metadata.json" ]]
}

@test "write_scan_manifest: missing SARIF fails (exit 2)" {
    run "$SCRIPT" osv-scanner "$TEST_DIR/osv/absent.sarif"
    [[ "$status" -eq 2 ]]
}

@test "write_scan_manifest: skips (no manifest, exit 0) when an error marker is present" {
    write_sarif '' "2.3.8"
    printf 'tool error\n' > "$TEST_DIR/osv/error"
    run "$SCRIPT" osv-scanner "$SARIF"
    [[ "$status" -eq 0 ]]
    [[ ! -f "$TEST_DIR/osv/manifest.json" ]]
}

@test "write_scan_manifest: usage error on wrong arg count" {
    run "$SCRIPT" osv-scanner
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"Usage:"* ]]
}
