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

@test "gen_policies: scorecard tenet is spliced literally (CEL && and \\. survive)" {
    # A gsub-based splice would reinterpret & (whole-match) and backslashes in
    # the tenet; run a copy of the generator against a fixture carrying both.
    local gendir="$BATS_TEST_TMPDIR/gendir" out="$BATS_TEST_TMPDIR/out"
    mkdir -p "$gendir" "$out"
    cp "$GEN_DIR/gen.sh" "$GEN_DIR/policy.hjson.in" "$gendir/"
    printf '%s\n' \
        '        {' \
        '            code: "score >= 7.0 && matches(id, \"v[0-9]\\.[0-9]\")"' \
        '        }' > "$gendir/scorecard-tenet.hjson.in"
    "$gendir/gen.sh" "$out"
    run grep -F 'code: "score >= 7.0 && matches(id, \"v[0-9]\\.[0-9]\")"' \
        "$out/wrangle-strict-go-v1.hjson"
    [ "$status" -eq 0 ]
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

# The provenance tier is hand-maintained outside the generator, so the
# release-pinned policy and release-tag identity it copies from the template
# need their own divergence check (eco-normalized byte equality across all 12).
@test "gen_policies: release-pinned policy + identity blocks match across every PolicySet" {
    local f block ref_block="" ident ref_ident=""
    for f in "$POLICIES_DIR"/wrangle-{default,strict,provenance}-*-v1.hjson; do
        block="$(sed -n '/\/\/ Advisory:/,/^        }$/p' "$f")"
        ident="$(sed -n '/id: "wrangle-builder-release-tag"/,/^            }$/p' "$f" \
                 | sed 's/build_and_publish_[a-z]*/build_and_publish_ECO/')"
        [ -n "$block" ]
        [ -n "$ident" ]
        if [ -z "$ref_block" ]; then ref_block="$block"; ref_ident="$ident"; continue; fi
        [ "$block" = "$ref_block" ]
        [ "$ident" = "$ref_ident" ]
    done
    [ -n "$ref_block" ]
}
