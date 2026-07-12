#!/usr/bin/env bats

# release_preflight.sh sequences the release gates. The gates themselves are
# covered by their own tests; what matters here is the aggregation contract —
# above all that an UNVERIFIED gate (exit 2, backend unreachable) fails closed
# rather than passing as "nothing to report".

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP_DIR="$(mktemp -d)"
    # A stand-in tools/ holding fake gates, so the aggregator's own logic is
    # exercised without running the real (network-dependent) checks.
    mkdir -p "$TMP_DIR/tools"
    cp "$REPO_ROOT/tools/release_preflight.sh" "$TMP_DIR/tools/"
}

teardown() {
    rm -rf "$TMP_DIR"
}

# Write a fake gate script that exits with the given code.
fake_gate() {
    local name="$1" code="$2" msg="${3:-}"
    printf '#!/bin/bash\n[[ -n "%s" ]] && printf "%%s\\n" "%s"\nexit %s\n' "$msg" "$msg" "$code" \
        > "$TMP_DIR/tools/$name"
    chmod +x "$TMP_DIR/tools/$name"
}

# Point the aggregator's gate list at the fakes.
all_gates_exit() {
    local code="$1" msg="${2:-}"
    for g in check_pin_ancestry.sh check_pin_freshness.sh check_pin_main_history.sh \
             check_catalog.sh check_catalog_freshness.sh check_catalog_provenance_freshness.sh; do
        fake_gate "$g" "$code" "$msg"
    done
}

@test "release_preflight: exits 0 and reports PASS when every gate passes" {
    all_gates_exit 0
    run "$TMP_DIR/tools/release_preflight.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"all 6 gate(s) satisfied"* ]]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" != *"FAIL"* ]]
}

@test "release_preflight: exits 1 and reports FAIL when a gate fails" {
    all_gates_exit 0
    fake_gate check_catalog_freshness.sh 1 "osv: catalog digest is behind :latest"
    run "$TMP_DIR/tools/release_preflight.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL        curated tool images not behind :latest"* ]]
    [[ "$output" == *"do not cut the tag"* ]]
}

@test "release_preflight: a failing gate's own remediation output is surfaced" {
    all_gates_exit 0
    fake_gate check_catalog_freshness.sh 1 "remediation: tools/bump_catalog_digest.sh osv sha256:beef"
    run "$TMP_DIR/tools/release_preflight.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"remediation: tools/bump_catalog_digest.sh osv sha256:beef"* ]]
}

@test "release_preflight: an unreachable backend (exit 2) is UNVERIFIED and fails closed" {
    # LOAD-BEARING. A gate that could not be evaluated must never read as
    # satisfied — an unproven release precondition is not a met one.
    all_gates_exit 0
    fake_gate check_catalog_provenance_freshness.sh 2 "attestation backend unreachable"
    run "$TMP_DIR/tools/release_preflight.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"UNVERIFIED  curated tool image digests built from current source"* ]]
    [[ "$output" == *"do not cut the tag"* ]]
}

@test "release_preflight: counts every unsatisfied gate, not just the first" {
    all_gates_exit 1
    run "$TMP_DIR/tools/release_preflight.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"6 of 6 gate(s) not satisfied"* ]]
}

@test "release_preflight: names the gates it does not cover, so they aren't assumed green" {
    all_gates_exit 0
    run "$TMP_DIR/tools/release_preflight.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"showcase"* ]]
    [[ "$output" == *"milestone"* ]]
}
