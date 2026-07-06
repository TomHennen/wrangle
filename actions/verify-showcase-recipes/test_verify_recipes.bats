#!/usr/bin/env bats

# Hermetic tests for tools/verify_documented_recipes.sh — no network, no live
# artifacts. Two layers:
#   - anti-drift: every documented recipe extracts to exactly one template block
#     and fully substitutes against the REAL docs/verifying_artifacts.md; a
#     duplicated, missing, or newly-placeheldered block fails closed.
#   - orchestration: with stub ampel/gh on PATH, a recipe's exit code drives the
#     script's PASS/FAIL and exit status, retry is bounded, and bad inputs are
#     rejected before anything runs.
# The real-tool pass/tamper checks against the captured fixtures need Sigstore,
# so they live in the integration suite (test/consumer), not here.

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$DIR/../.." && pwd)"
    SCRIPT="$REPO_ROOT/tools/verify_documented_recipes.sh"
    DOC="$REPO_ROOT/docs/verifying_artifacts.md"
    STUB="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB"
    HEX="$(printf 'x' | sha256sum | cut -d' ' -f1)"
    export DIR REPO_ROOT SCRIPT DOC STUB HEX
}

# A stub that echoes its argv and exits ${STUB_RC:-0}, so orchestration tests
# assert exit-code plumbing and the substituted command line without a real tool.
_stub() {
    local name="$1"
    printf '#!/usr/bin/env bash\nprintf "STUB %s %%s\\n" "$*"\nexit ${STUB_RC:-0}\n' "$name" > "$STUB/$name"
    chmod +x "$STUB/$name"
}

# --- anti-drift: selection + substitution against the real doc ----------------

@test "every documented recipe selects exactly one template block from the real doc" {
    run bash -c '
        source "$SCRIPT"
        for sig in \
            "--collector jsonl:<artifact>" \
            "sha256sum <artifact>" \
            ".predicate.verifiedLevels[]" \
            "--collector oci:" \
            "cosign download attestation" \
            "--collector github:" \
            "gh attestation verify"; do
            _select_block "$sig" >/dev/null || exit 1
        done
        echo ALL_SELECTED
    '
    [[ "$status" -eq 0 ]]
    [[ "$output" == *ALL_SELECTED* ]]
}

@test "every recipe substitutes with no placeholder left over against the real doc" {
    run bash -c '
        source "$SCRIPT"
        REPO="o/r"; RESOURCE_URI="pkg:npm/x@1"; ARTIFACT_NAME="a.tgz"
        IMAGE_NAME="ghcr.io/o/i"; DIGEST="'"$HEX"'"; BUILD_TYPE="npm"; NON_STRICT=0
        for sig in \
            "--collector jsonl:<artifact>" "sha256sum <artifact>" \
            ".predicate.verifiedLevels[]" "--collector oci:" \
            "cosign download attestation" "--collector github:" \
            "gh attestation verify"; do
            _substitute "$(_select_block "$sig")" >/dev/null || exit 1
        done
        echo ALL_SUBSTITUTED
    '
    [[ "$status" -eq 0 ]]
    [[ "$output" == *ALL_SUBSTITUTED* ]]
}

@test "non-strict swaps the ampel policy to the non-strict variant" {
    run bash -c '
        source "$SCRIPT"
        REPO="o/r"; RESOURCE_URI="pkg:npm/x@1"; ARTIFACT_NAME="a.tgz"
        IMAGE_NAME=""; DIGEST=""; BUILD_TYPE="npm"; NON_STRICT=1
        _substitute "$(_select_block "--collector jsonl:<artifact>")"
    '
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"wrangle-vsa-consumer-nonstrict-v1.hjson"* ]]
}

@test "non-strict relaxes the cosign release-tag anchor to any ref" {
    run bash -c '
        source "$SCRIPT"
        REPO="o/r"; RESOURCE_URI="pkg:npm/x@1"; ARTIFACT_NAME="a.tgz"
        IMAGE_NAME=""; DIGEST=""; BUILD_TYPE="npm"; NON_STRICT=1
        _substitute "$(_select_block "sha256sum <artifact>")"
    '
    [[ "$status" -eq 0 ]]
    # The strict release-tag anchor must be gone; the workflow prefix stays.
    [[ "$output" != *"refs/tags/v[0-9.]+"* ]]
    [[ "$output" == *'build_and_publish_npm\.yml@'* ]]
}

@test "a newly-added placeholder in the doc fails the substitution guard" {
    printf '```bash\nampel verify --subject <artifact> --context foo:<brand-new>\n```\n' \
        > "$BATS_TEST_TMPDIR/drift.md"
    export WRANGLE_RECIPES_DOC="$BATS_TEST_TMPDIR/drift.md"
    run bash -c '
        source "$SCRIPT"
        REPO=o/r; RESOURCE_URI=x; ARTIFACT_NAME=a; IMAGE_NAME=; DIGEST=; BUILD_TYPE=go; NON_STRICT=0
        _substitute "$(_select_block "--subject <artifact>")"
    '
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"unsubstituted placeholder"* ]]
}

@test "a duplicated recipe block fails selection (drift, not silent pick)" {
    printf '```bash\nfoo --collector oci: one\n```\n```bash\nfoo --collector oci: two\n```\n' \
        > "$BATS_TEST_TMPDIR/dup.md"
    export WRANGLE_RECIPES_DOC="$BATS_TEST_TMPDIR/dup.md"
    run bash -c 'source "$SCRIPT"; _select_block "--collector oci:"'
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"found 2"* ]]
}

@test "a missing recipe block fails selection" {
    printf '```bash\nunrelated command\n```\n' > "$BATS_TEST_TMPDIR/missing.md"
    export WRANGLE_RECIPES_DOC="$BATS_TEST_TMPDIR/missing.md"
    run bash -c 'source "$SCRIPT"; _select_block "--collector oci:"'
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"found 0"* ]]
}

# --- orchestration: stub-driven exit-code plumbing + retry --------------------

@test "attestation-store recipe PASSES when ampel exits 0" {
    _stub ampel
    PATH="$STUB:$PATH" WRANGLE_RECIPE_RETRY_DELAY=0 run "$SCRIPT" \
        --attestation-store --repo o/r --resource-uri "pkg:npm/x@1" --digest "$HEX"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS:"* ]]
    [[ "$output" == *"1 passed, 0 failed"* ]]
}

@test "attestation-store recipe FAILS (exit 1) and retries when ampel keeps failing" {
    _stub ampel
    PATH="$STUB:$PATH" STUB_RC=1 WRANGLE_RECIPE_RETRIES=3 WRANGLE_RECIPE_RETRY_DELAY=0 run "$SCRIPT" \
        --attestation-store --repo o/r --resource-uri "pkg:npm/x@1" --digest "$HEX"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"attempt 1/3"* ]]
    [[ "$output" == *"attempt 2/3"* ]]
    [[ "$output" == *"FAIL:"* ]]
}

@test "non-strict flag reaches the executed ampel command line" {
    _stub ampel
    PATH="$STUB:$PATH" WRANGLE_RECIPE_RETRY_DELAY=0 run "$SCRIPT" \
        --attestation-store --repo o/r --resource-uri "pkg:npm/x@1" --digest "$HEX" --non-strict
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"nonstrict"* ]]
}

@test "provenance recipe PASSES when gh exits 0" {
    _stub gh
    printf 'x' > "$BATS_TEST_TMPDIR/art.tgz"
    PATH="$STUB:$PATH" WRANGLE_RECIPE_RETRY_DELAY=0 run "$SCRIPT" \
        --provenance --file "$BATS_TEST_TMPDIR/art.tgz" --repo o/r --type npm
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"build_and_publish_npm.yml"* ]]
    [[ "$output" == *"1 passed, 0 failed"* ]]
}

# --- input validation (fail before any recipe runs, exit 2) ------------------

@test "rejects a malformed --repo" {
    run "$SCRIPT" --attestation-store --repo not-a-repo --resource-uri x --digest "$HEX"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"bad --repo"* ]]
}

@test "rejects a non-hex --digest" {
    run "$SCRIPT" --attestation-store --repo o/r --resource-uri x --digest NOTHEX
    [[ "$status" -eq 2 ]]
}

@test "rejects an unknown build --type" {
    printf 'x' > "$BATS_TEST_TMPDIR/art.tgz"
    run "$SCRIPT" --provenance --file "$BATS_TEST_TMPDIR/art.tgz" --repo o/r --type rust
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"bad --type"* ]]
}

@test "rejects an unknown flag" {
    run "$SCRIPT" --bogus
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"unknown argument"* ]]
}

@test "no coordinates prints usage and exits 2" {
    run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"Usage:"* ]]
}
