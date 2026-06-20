#!/usr/bin/env bats

# Generator for the per-eco default/strict PolicySets. The committed
# policies/wrangle-{default,strict}-<eco>-v1.hjson are generated from
# policy.hjson.in; this asserts they are in sync (drift detector) and that the
# generator produces well-formed, distinct output. Offline + hermetic — no
# ampel, no network — so it lives in the unit suite.

setup() {
    GEN_DIR="$BATS_TEST_DIRNAME"
    REPO_ROOT="$(cd "$GEN_DIR/../.." && pwd)"
    POLICIES_DIR="$REPO_ROOT/policies"
    ECOS=(go npm python container)
}

@test "gen_policies: committed PolicySets match the generator output (no drift)" {
    "$GEN_DIR/gen.sh" "$BATS_TEST_TMPDIR"
    for eco in "${ECOS[@]}"; do
        for tier in default strict; do
            local name="wrangle-$tier-$eco-v1.hjson"
            run diff -u "$POLICIES_DIR/$name" "$BATS_TEST_TMPDIR/$name"
            [ "$status" -eq 0 ] || {
                printf 'committed %s drifted from gen.sh — run tools/gen_policies/gen.sh\n' "$name" >&2
                printf '%s\n' "$output" >&2
                return 1
            }
        done
    done
}

@test "gen_policies: each generated PolicySet bakes its own eco builder workflow" {
    "$GEN_DIR/gen.sh" "$BATS_TEST_TMPDIR"
    for eco in "${ECOS[@]}"; do
        for tier in default strict; do
            run grep -q "build_and_publish_$eco\.yml" "$BATS_TEST_TMPDIR/wrangle-$tier-$eco-v1.hjson"
            [ "$status" -eq 0 ]
        done
    done
}

@test "gen_policies: strict adds the scorecard tenet, default omits it" {
    "$GEN_DIR/gen.sh" "$BATS_TEST_TMPDIR"
    run grep -q "wrangle-scorecard-min-score" "$BATS_TEST_TMPDIR/wrangle-strict-go-v1.hjson"
    [ "$status" -eq 0 ]
    run grep -q "wrangle-scorecard-min-score" "$BATS_TEST_TMPDIR/wrangle-default-go-v1.hjson"
    [ "$status" -ne 0 ]
}

@test "gen_policies: every generated PolicySet keeps the identity-binding markers" {
    "$GEN_DIR/gen.sh" "$BATS_TEST_TMPDIR"
    for eco in "${ECOS[@]}"; do
        for tier in default strict; do
            run grep -c "AMPEL-IDENTITY-BINDING" "$BATS_TEST_TMPDIR/wrangle-$tier-$eco-v1.hjson"
            [ "$output" -eq 2 ]
        done
    done
}
