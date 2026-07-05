#!/usr/bin/env bats

# Unit tests for the VSA gate primitive (lib/verify_image_vsa.sh, #596),
# exercised directly: the verdict/resourceUri assertion against captured real
# `gh attestation verify --format json` output, and verify_image_vsa's
# retry/fail-closed control flow against a gh shim. The real-gh contract (a live
# published image, real identity/ref rejection) is covered by
# test/image/test_verify_tool_image_real_gh.bats.

# The osv attestation's resourceUri (== the digest-pinned image ref) in the real
# fixture; the gate binds resourceUri to the requested image.
_osv_uri="ghcr.io/tomhennen/wrangle/osv@sha256:c8abda59e3a64520128c427d2fe9bd223c27e0a2056181ead1b9d3c6a5fb3b75"
_image="ghcr.io/tomhennen/wrangle/imgtool@sha256:c8abda59e3a64520128c427d2fe9bd223c27e0a2056181ead1b9d3c6a5fb3b75"

# A shared clean bin of symlinks to every real tool on PATH except gh and jq —
# the two the per-test setup shims or drops.
setup_file() {
    SHARED_BIN="$BATS_FILE_TMPDIR/bin"
    mkdir -p "$SHARED_BIN"
    local dir f name
    IFS=':' read -ra _dirs <<< "$PATH"
    for dir in "${_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -x "$f" && ! -d "$f" ]] || continue
            name="${f##*/}"
            [[ "$name" == gh || "$name" == jq ]] && continue
            [[ -e "$SHARED_BIN/$name" ]] || ln -s "$f" "$SHARED_BIN/$name"
        done
    done
    export SHARED_BIN
}

setup() {
    LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/verify_image_vsa.sh"
    FIXTURES="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/test/fixtures/tool-image-vsa"
    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-vsa.XXXXXX")"
    BIN="$TMP_DIR/bin"
    COUNT="$TMP_DIR/gh.count"
    mkdir -p "$BIN"
    : > "$COUNT"

    # Writable overlay ahead of the shared farm: the gh shim and this jq symlink
    # are what tests add or drop to probe the env-error paths.
    ln -s "$(command -v jq)" "$BIN/jq"
    CLEAN_PATH="$BIN:$SHARED_BIN"

    # shellcheck source=/dev/null
    source "$LIB"
    # The shim emits this as the VSA's resourceUri; matches $_image so the gate's
    # resourceUri binding is satisfied unless a test overrides it.
    GH_RESOURCE_URI="$_image"
    export TMP_DIR BIN COUNT FIXTURES GH_RESOURCE_URI CLEAN_PATH
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

# gh shim: counts invocations and replays a scripted sequence of outcomes from
# GH_SEQ (space-separated, one per attempt; the last repeats). Each outcome is a
# stdout/stderr/exit shape of real `gh attestation verify`.
_install_gh_shim() {
    cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
n=$(($(wc -l < "$GH_COUNT") + 1)); printf '\n' >> "$GH_COUNT"
read -ra seq <<< "$GH_SEQ"
mode="${seq[n-1]:-${seq[${#seq[@]}-1]}}"
case "$mode" in
    transient) printf 'Error: tuf refresh failed: dial tcp: connection refused\n' >&2; exit 1 ;;
    noattest)  printf 'Error: no attestations found in the OCI registry\n' >&2; exit 1 ;;
    timeout)   exit 124 ;;
    malformed) printf 'not json at all\n' ;;
    failed|passed|nol3)
        verdict=PASSED; levels='["SLSA_BUILD_LEVEL_3"]'
        [[ "$mode" == failed ]] && verdict=FAILED
        [[ "$mode" == nol3 ]]   && levels='["SLSA_BUILD_LEVEL_2"]'
        printf '[{"verificationResult":{"statement":{"predicate":{"verificationResult":"%s","resourceUri":"%s","verifiedLevels":%s}}}}]\n' \
            "$verdict" "${GH_RESOURCE_URI:-}" "$levels"
        ;;
esac
GH
    chmod +x "$BIN/gh"
}

# --- vsa_assert_passed_l3: the verdict + resourceUri check, against real output

@test "assert: real captured PASSED osv attestation, matching resourceUri -> accepted" {
    run bash -c "source '$LIB'; vsa_assert_passed_l3 '$_osv_uri' < '$FIXTURES/osv_passed_vsa.json'"
    [ "$status" -eq 0 ]
}

@test "assert: real PASSED attestation but WRONG expected resourceUri -> rejected" {
    run bash -c "source '$LIB'; vsa_assert_passed_l3 'ghcr.io/tomhennen/wrangle/other@sha256:dead' < '$FIXTURES/osv_passed_vsa.json'"
    [ "$status" -ne 0 ]
}

@test "assert: empty array -> rejected" {
    run bash -c "source '$LIB'; printf '[]' | vsa_assert_passed_l3 '$_image'"
    [ "$status" -ne 0 ]
}

@test "assert: FAILED verdict -> rejected" {
    body='[{"verificationResult":{"statement":{"predicate":{"verificationResult":"FAILED","resourceUri":"'$_image'","verifiedLevels":["SLSA_BUILD_LEVEL_3"]}}}}]'
    run bash -c "source '$LIB'; printf '%s' '$body' | vsa_assert_passed_l3 '$_image'"
    [ "$status" -ne 0 ]
}

@test "assert: PASSED but not SLSA Build L3 -> rejected" {
    body='[{"verificationResult":{"statement":{"predicate":{"verificationResult":"PASSED","resourceUri":"'$_image'","verifiedLevels":["SLSA_BUILD_LEVEL_2"]}}}}]'
    run bash -c "source '$LIB'; printf '%s' '$body' | vsa_assert_passed_l3 '$_image'"
    [ "$status" -ne 0 ]
}

@test "assert: malformed JSON -> rejected" {
    run bash -c "source '$LIB'; printf 'not json' | vsa_assert_passed_l3 '$_image'"
    [ "$status" -ne 0 ]
}

# --- verify_image_vsa: env pre-checks (fail closed with a clear message)

@test "verify: gh absent -> rc 2, clear message" {
    # BIN excludes gh and no shim is installed.
    run env PATH="$CLEAN_PATH" bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"gh not found"* ]]
}

@test "verify: jq absent -> rc 2, clear message" {
    _install_gh_shim
    rm -f "$BIN/jq"
    run env PATH="$CLEAN_PATH" GH_COUNT="$COUNT" GH_SEQ="passed" bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"jq not found"* ]]
}

# --- verify_image_vsa: verdict outcomes (the verdict check is never retried)

@test "verify: attested PASSED L3, resourceUri matches -> rc 0, one gh call" {
    _install_gh_shim
    run env PATH="$CLEAN_PATH" GH_COUNT="$COUNT" GH_SEQ="passed" WRANGLE_RETRY_DELAY=0 \
        bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$COUNT")" -eq 1 ]
}

@test "verify: PASSED L3 but resourceUri is a DIFFERENT image -> rc 1, not retried" {
    _install_gh_shim
    run env PATH="$CLEAN_PATH" GH_COUNT="$COUNT" GH_SEQ="passed" WRANGLE_RETRY_DELAY=0 \
        GH_RESOURCE_URI="ghcr.io/tomhennen/wrangle/other@sha256:dead" \
        bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 1 ]
    # gh succeeded (rc 0), so the deterministic verdict failure is not retried.
    [ "$(wc -l < "$COUNT")" -eq 1 ]
}

@test "verify: gh rc 0 but FAILED verdict -> rc 1, not retried" {
    _install_gh_shim
    run env PATH="$CLEAN_PATH" GH_COUNT="$COUNT" GH_SEQ="failed" WRANGLE_RETRY_DELAY=0 \
        bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$COUNT")" -eq 1 ]
}

@test "verify: malformed gh JSON -> rc 1, fail closed, not retried" {
    _install_gh_shim
    run env PATH="$CLEAN_PATH" GH_COUNT="$COUNT" GH_SEQ="malformed" WRANGLE_RETRY_DELAY=0 \
        bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$COUNT")" -eq 1 ]
}

# --- verify_image_vsa: retry control flow (a failed gh call is retried once)

@test "verify: no-attestation failure -> rc 1, retried once" {
    _install_gh_shim
    run env PATH="$CLEAN_PATH" GH_COUNT="$COUNT" GH_SEQ="noattest" WRANGLE_RETRY_DELAY=0 \
        bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$COUNT")" -eq 2 ]
}

@test "verify: transient gh failure then success -> rc 0, two gh calls" {
    _install_gh_shim
    run env PATH="$CLEAN_PATH" GH_COUNT="$COUNT" GH_SEQ="transient passed" WRANGLE_RETRY_DELAY=0 \
        bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$COUNT")" -eq 2 ]
}

@test "verify: persistent gh failure -> rc 1, retried once then fails closed" {
    _install_gh_shim
    run env PATH="$CLEAN_PATH" GH_COUNT="$COUNT" GH_SEQ="transient" WRANGLE_RETRY_DELAY=0 \
        bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$COUNT")" -eq 2 ]
}

@test "verify: gh timeout then success -> rc 0 (timeout exit is retried)" {
    _install_gh_shim
    run env PATH="$CLEAN_PATH" GH_COUNT="$COUNT" GH_SEQ="timeout passed" WRANGLE_RETRY_DELAY=0 \
        bash -c "source '$LIB'; verify_image_vsa '$_image'"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$COUNT")" -eq 2 ]
}
