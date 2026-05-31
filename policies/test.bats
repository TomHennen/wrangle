#!/usr/bin/env bats

# Policy harness for the wrangle Ampel PolicySets (policies/*.hjson).
#
# This is the drift detector the design calls "the single most important
# deliverable" (docs/ampel_research.md §5): HJSON+CEL+context errors are
# otherwise silent. Each test runs the REAL `ampel verify` against a fixture
# attestation bundle in policies/testdata/ and asserts the pass/fail result.
#
# Requires the real ampel binary (built from tools/go.mod:
# `go -C tools install tool`) AND github.com reachability — Ampel resolves the
# SHA-pinned upstream policy locators at verify time. It is therefore an
# INTEGRATION test: it is not in the Makefile `bats` glob (the offline unit
# container) and runs only in the dedicated `ampel policies` job in
# .github/workflows/test.yml. The skip guards below keep local sandboxed dev
# from hard-failing; CI rejects any silent skip.
#
# -- Two things are under test, and they need different policies ----------
# 1. TENET LOGIC (builder-id / build-type / build-point / sbom / osv /
#    scorecard CEL). The testdata fixtures are UNSIGNED jsonl statements, so
#    they cannot satisfy the PolicySets' signer-identity admission. Each logic
#    test therefore runs against a LOGIC-ONLY VARIANT derived at setup time by
#    strip_identities() — the production CEL byte-identical, minus the identity
#    gate. Routing ALL logic tests (PASS *and* FAIL) through the variant is
#    deliberate: against the production policy an unsigned fixture fails at the
#    identity gate BEFORE the tenet CEL runs, so a FAIL test would pass
#    vacuously even with broken builder-id logic.
# 2. IDENTITY ENFORCEMENT. The fail-closed test runs the PRODUCTION policy
#    against the same good fixture that PASSES the variant, and asserts it is
#    rejected specifically on signer-identity validation — proving the binding
#    is wired and fail-closed without a --signer flag to forget.
#
# The variant is derived (not committed) so it cannot drift from production.

# Derive a logic-only PolicySet from a production one: delete the
# marker-delimited common.identities block and the per-policy identity refs,
# leaving every tenet (and its meta.controls) byte-identical. See the
# AMPEL-IDENTITY-BINDING markers in policies/*.hjson.
strip_identities() {
    sed -e '/AMPEL-IDENTITY-BINDING:START/,/AMPEL-IDENTITY-BINDING:END/d' \
        -e '/^[[:space:]]*identities: \[ { ref: { id: "slsa-generator" } } \]$/d' "$1"
}

# skip_or_fail (fail-not-skip under CI) lives in a shared bats helper.
load "../test/lib/bats_helpers"

setup() {
    AMPEL="$(command -v ampel || true)"
    [ -n "$AMPEL" ] || skip_or_fail "ampel not installed (build via tools/go.mod: go -C tools install tool)"
    # Ampel must reach github.com to resolve the upstream policy locators.
    curl -fsS -m 10 -o /dev/null https://github.com 2>/dev/null || skip_or_fail "github.com unreachable"

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

    # Logic-only variants for the tenet tests (see the file header).
    DEFAULT_LOGIC="$BATS_TEST_TMPDIR/default-logic.hjson"
    STRICT_LOGIC="$BATS_TEST_TMPDIR/strict-logic.hjson"
    strip_identities "$DEFAULT" > "$DEFAULT_LOGIC"
    strip_identities "$STRICT"  > "$STRICT_LOGIC"
    # Structural self-check: a broken strip would silently turn every logic test
    # into a vacuous identity-gate check. Fail loudly if any identity admission
    # survived. (The PASS tests are the functional half of this guard: if the
    # gate were still present, the unsigned good fixtures could not pass.)
    if grep -qE '^[[:space:]]*identities:' "$DEFAULT_LOGIC" "$STRICT_LOGIC"; then
        printf 'strip_identities left an identities admission in the logic variant\n' >&2
        return 1
    fi

    export AMPEL POLICIES_DIR DEFAULT STRICT DEFAULT_LOGIC STRICT_LOGIC TD SUBJECT CTX
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

# --- Tenet logic (logic-only variant: identity gate stripped) --------------

@test "ampel policy: default-v1 PASSES a good release bundle (SLSA_BUILD_LEVEL_3)" {
    local vsa="$BATS_TEST_TMPDIR/vsa.json"
    run verify "$DEFAULT_LOGIC" "$TD/good.bundle.jsonl" \
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
    expect_fail "$DEFAULT_LOGIC" "$TD/bad-missing-sbom.bundle.jsonl" "sbom-exists"
}

@test "ampel policy: default-v1 FAILS (openvex) on an OSV vulnerability" {
    expect_fail "$DEFAULT_LOGIC" "$TD/bad-osv-vuln.bundle.jsonl" "openvex-no-exploitable-vulns"
}

@test "ampel policy: default-v1 FAILS (slsa-builder-id) on a wrong builder identity" {
    # Against the logic variant the builder-id CEL is what rejects the attacker
    # builder — not the identity gate — so this exercises the tenet, not admission.
    expect_fail "$DEFAULT_LOGIC" "$TD/bad-wrong-builder.bundle.jsonl" "slsa-builder-id"
}

@test "ampel policy: default-v1 FAILS (slsa-build-type) on a wrong build type" {
    expect_fail "$DEFAULT_LOGIC" "$TD/bad-wrong-buildtype.bundle.jsonl" "slsa-build-type"
}

@test "ampel policy: default-v1 FAILS (slsa-build-point) on a wrong source repo" {
    expect_fail "$DEFAULT_LOGIC" "$TD/bad-wrong-buildpoint.bundle.jsonl" "slsa-build-point"
}

@test "ampel policy: strict-v1 PASSES a good bundle with Scorecard >= 7" {
    run verify "$STRICT_LOGIC" "$TD/good-strict.bundle.jsonl" -f tty
    [ "$status" -eq 0 ]
}

@test "ampel policy: strict-v1 FAILS (scorecard) when the Scorecard score is below 7" {
    expect_fail "$STRICT_LOGIC" "$TD/bad-low-scorecard.bundle.jsonl" "wrangle-scorecard-min-score"
}

# --- Identity enforcement (production policy: identity gate intact) --------

@test "ampel policy: default-v1 (production) is FAIL-CLOSED — rejects an unsigned attestation on signer identity" {
    local rs="$BATS_TEST_TMPDIR/enforce.json"
    # Production policy (identity bindings intact) against the SAME good fixture
    # that PASSES the logic variant, so the only thing that can fail is the
    # signer-identity admission (the fixtures are unsigned jsonl statements).
    run verify "$DEFAULT" "$TD/good.bundle.jsonl" \
        --attest-results --attest-format=ampel --results-path="$rs" -f tty
    [ "$status" -ne 0 ]
    [ -s "$rs" ]
    run jq -r '.predicate.status' "$rs"
    [ "$output" = "FAIL" ]
    # The provenance policy fails specifically on identity validation — not on
    # its tenet CEL (the logic variant proves that CEL passes on this fixture).
    run jq -r '.predicate.results[] | select(.policy.id == "slsa-builder-id") | .status' "$rs"
    [ "$output" = "FAIL" ]
    run jq -r '[.predicate.results[].eval_results[]?.error.message]
               | map(select(. == "attestation identity validation failed")) | length' "$rs"
    [ "$output" -ge 1 ]
}

# --- Cross-file invariant --------------------------------------------------

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
