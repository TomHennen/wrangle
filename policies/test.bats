#!/usr/bin/env bats

# Policy harness for the wrangle Ampel PolicySets (policies/*.hjson).
#
# This is the drift detector the design calls "the single most important
# deliverable" (docs/ampel_research.md §5): HJSON+CEL+context errors are
# otherwise silent. Each test runs the REAL `ampel verify` against a fixture
# attestation bundle in policies/testdata/ and asserts the pass/fail result.
#
# Requires the real ampel binary (tools/ampel/install.sh) AND github.com
# reachability — Ampel resolves the SHA-pinned upstream policy locators at
# verify time. It is therefore an INTEGRATION test: it is not in the Makefile
# `bats` glob (the offline unit container) and runs only in the dedicated
# `ampel policies` job in .github/workflows/test.yml. The skip guards below
# keep local sandboxed dev from hard-failing; CI rejects any silent skip.

setup() {
    AMPEL="$(command -v ampel || true)"
    [ -n "$AMPEL" ] || skip "ampel not installed (run tools/ampel/install.sh)"
    # Ampel must reach github.com to resolve the upstream policy locators.
    curl -fsS -m 10 -o /dev/null https://github.com 2>/dev/null || skip "github.com unreachable"

    POLICIES_DIR="$BATS_TEST_DIRNAME"
    DEFAULT="$POLICIES_DIR/wrangle-default-v1.hjson"
    STRICT="$POLICIES_DIR/wrangle-strict-v1.hjson"
    TD="$POLICIES_DIR/testdata"
    # sha256 of the literal "wrangle-app-1.0.0.tgz" — the subject baked into
    # every fixture bundle (see the generator note in testdata/).
    SUBJECT="sha256:2b27ffb5258939a2700ecf4667a040192e717bfee6446dcad995563fed8a9c0a"
    # Per-release context the caller supplies at verify time, in the SAME
    # colon-pair --context format actions/verify forwards to ampel (so the
    # harness exercises the production parser, not the JSON-only --context-json).
    CTX="buildPoint:git+https://github.com/TomHennen/wrangle,vsa.resourceUri:pkg:generic/wrangle-app@1.0.0"
    export AMPEL POLICIES_DIR DEFAULT STRICT TD SUBJECT CTX
}

# verify <policy> <fixture-bundle> [extra ampel args...]
verify() {
    local policy="$1" bundle="$2"; shift 2
    "$AMPEL" verify -p "$policy" -s "$SUBJECT" -c "jsonl:$bundle" \
        -x "$CTX" "$@"
}

# expect_fail <policy> <fixture-bundle> <expected-failing-policy-id>
# Asserts the set FAILS *because of the named tenet* — not merely exit!=0.
# Emits the machine-readable ampel resultset (written even on FAIL) and checks
# the specific policy's status. An infrastructure error (bad SHA, github.com
# flake, ampel regression) errors out before a resultset is written, so it
# cannot satisfy this assertion vacuously.
expect_fail() {
    local policy="$1" bundle="$2" want="$3"
    local rs="$BATS_TEST_TMPDIR/resultset.json"
    run verify "$policy" "$bundle" --attest-results --attest-format=ampel --results-path="$rs" -f tty
    [ "$status" -ne 0 ]
    [ -s "$rs" ]
    run jq -r '.predicate.status' "$rs"
    [ "$output" = "FAIL" ]
    run jq -r --arg id "$want" '.predicate.results[] | select(.policy.id == $id) | .status' "$rs"
    [ "$output" = "FAIL" ]
}

@test "ampel policy: default-v1 PASSES a good release bundle (SLSA_BUILD_LEVEL_3)" {
    local vsa="$BATS_TEST_TMPDIR/vsa.json"
    run verify "$DEFAULT" "$TD/good.bundle.jsonl" \
        --attest-results --attest-format=vsa --results-path="$vsa" -f tty
    [ "$status" -eq 0 ]
    # The signed VSA must record PASSED, the SLSA build level, and the resourceUri.
    run jq -r '.predicate.verificationResult' "$vsa"
    [ "$output" = "PASSED" ]
    run jq -r '.predicate.verifiedLevels[0]' "$vsa"
    [ "$output" = "SLSA_BUILD_LEVEL_3" ]
    run jq -r '.predicate.resourceUri' "$vsa"
    [ "$output" = "pkg:generic/wrangle-app@1.0.0" ]
}

@test "ampel policy: default-v1 FAILS (sbom-exists) when the SBOM is missing" {
    expect_fail "$DEFAULT" "$TD/bad-missing-sbom.bundle.jsonl" "sbom-exists"
}

@test "ampel policy: default-v1 FAILS (openvex) on an OSV vulnerability" {
    expect_fail "$DEFAULT" "$TD/bad-osv-vuln.bundle.jsonl" "openvex-no-exploitable-vulns"
}

@test "ampel policy: default-v1 FAILS (slsa-builder-id) on a wrong builder identity" {
    expect_fail "$DEFAULT" "$TD/bad-wrong-builder.bundle.jsonl" "slsa-builder-id"
}

@test "ampel policy: strict-v1 PASSES a good bundle with Scorecard >= 7" {
    run verify "$STRICT" "$TD/good-strict.bundle.jsonl" -f tty
    [ "$status" -eq 0 ]
}

@test "ampel policy: strict-v1 FAILS (scorecard) when the Scorecard score is below 7" {
    expect_fail "$STRICT" "$TD/bad-low-scorecard.bundle.jsonl" "wrangle-scorecard-min-score"
}

@test "ampel policy: every upstream locator is SHA-pinned to one identical commit (§8 risk 8)" {
    # Decision 2: every carabiner-dev/policies reference must pin the SAME 40-hex
    # commit. Assert it POSITIVELY — pull the ref token out of every
    # `carabiner-dev/policies@<ref>#` locator and require each to be 40 hex.
    # (A negative "no unpinned '#'" grep is evadable: a moving '@main'/'@v1.0.0'
    # ref contributes no 40-hex match and contains no bare 'policies#', so it
    # would slip past — exactly the moving-ref the pin exists to forbid.)
    local refs
    refs="$(grep -rhoE 'carabiner-dev/policies@[^#"]+' "$POLICIES_DIR"/*.hjson | sed 's/.*@//' | sort -u)"
    # At least one locator exists, and they all resolve to one ref.
    [ -n "$refs" ]
    [ "$(printf '%s\n' "$refs" | wc -l)" -eq 1 ]
    # That ref is a full commit SHA, not a branch or tag.
    printf '%s\n' "$refs" | grep -qxE '[0-9a-f]{40}'
}
