#!/usr/bin/env bats

# Tests for the attest-job metadata signing (issue #550):
#   resolve_subjects.sh — derive the dist subjects (go checksums / npm-python glob)
#   sign_metadata.sh     — wrangle-attest --sign per subject + bnd store push
#
# wrangle-attest runs for real (it self-digests offline); bnd is stubbed because
# the keyless --sign + store push need OIDC/network. The M4 invariant — attest
# binds the SAME sha256 subject the verify job binds the VSA to — is asserted by
# comparing the attest statement's subject digest to the sha256sum the verify
# subject builder (run_verify.sh wrangle_subject_arg) computes from the same file.
load "../../test/lib/bats_helpers"

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$DIR/../.." && pwd)"
    SIGN="$DIR/sign_metadata.sh"
    RESOLVE="$DIR/resolve_subjects.sh"
    TEST_DIR="$(mktemp -d)"
    export DIR REPO_ROOT SIGN RESOLVE TEST_DIR

    # A real built dist file + a metadata dir with the SBOM manifest the engine
    # discovers and signs.
    DIST="$TEST_DIR/dist"
    META="$TEST_DIR/meta"
    mkdir -p "$DIST" "$META"
    printf 'artifact-bytes-v1.2.3' > "$DIST/app-1.2.3.tgz"
    printf '{"spdxVersion":"SPDX-2.3"}' > "$META/sbom.spdx.json"
    printf '{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}' \
        > "$META/wrangle_attestation_metadata.json"
    export DIST META

    GITHUB_OUTPUT="$TEST_DIR/gh_output"
    : > "$GITHUB_OUTPUT"
    export GITHUB_OUTPUT
    export RUNNER_TEMP="$TEST_DIR"
    export WRANGLE_BIN_DIR="$TEST_DIR/bin"
    export WRANGLE_RETRY_DELAY=0

    ATTEST_BIN="$(command -v wrangle-attest || echo "${WRANGLE_BIN_DIR}/wrangle-attest")"
    export ATTEST_BIN
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Build a fake bnd on PATH that records each `push github <repo> <file>` and
# copies the pushed statement aside so a test can inspect what was posted.
stub_bnd() {
    STUB_BIN="$TEST_DIR/stubbin"
    mkdir -p "$STUB_BIN"
    PUSH_RECORD="$TEST_DIR/bnd-push-record"
    PUSHED_DIR="$TEST_DIR/pushed"
    mkdir -p "$PUSHED_DIR"
    : > "$PUSH_RECORD"
    export STUB_BIN PUSH_RECORD PUSHED_DIR
    cat > "$STUB_BIN/bnd" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "push" && "${2:-}" == "github" ]]; then
    printf '%s %s\n' "$3" "$4" >> "$PUSH_RECORD"
    cat "$4" >> "$PUSHED_DIR/all.jsonl"
fi
exit 0
STUB
    chmod +x "$STUB_BIN/bnd"
}

# ---- resolve_subjects.sh ----

@test "resolve_subjects: npm/python glob lists each dist file" {
    SUBJECT_PATH="$DIST/*" SUBJECT_CHECKSUMS="" run "$RESOLVE"
    [ "$status" -eq 0 ]
    grep -q "subjects<<" "$GITHUB_OUTPUT"
    grep -Fq "$DIST/app-1.2.3.tgz" "$GITHUB_OUTPUT"
}

@test "resolve_subjects: go checksums file lists each named dist file" {
    printf '%s  %s\n' deadbeef app-1.2.3.tgz > "$TEST_DIR/checksums.txt"
    SUBJECT_CHECKSUMS="$TEST_DIR/checksums.txt" SUBJECT_PATH="" DIST_DIR="$DIST" run "$RESOLVE"
    [ "$status" -eq 0 ]
    grep -Fq "$DIST/app-1.2.3.tgz" "$GITHUB_OUTPUT"
}

@test "resolve_subjects: rejects zero or both subject inputs" {
    SUBJECT_PATH="" SUBJECT_CHECKSUMS="" run "$RESOLVE"
    [ "$status" -ne 0 ]
    SUBJECT_PATH="$DIST/*" SUBJECT_CHECKSUMS="$TEST_DIR/c.txt" run "$RESOLVE"
    [ "$status" -ne 0 ]
}

@test "resolve_subjects: a glob matching nothing fails closed" {
    SUBJECT_PATH="$TEST_DIR/nope/*" SUBJECT_CHECKSUMS="" run "$RESOLVE"
    [ "$status" -ne 0 ]
}

# ---- sign_metadata.sh (arg shape, no real tools) ----

@test "sign_metadata: a file subject is self-digested via --artifact and signed" {
    export METADATA_ROOT="$META" COMMIT="abc123" WRANGLE_RETRY_DELAY=0
    # A stub wrangle-attest records its args so we can assert the derived flags.
    STUB_BIN="$TEST_DIR/stubbin"; mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/wrangle-attest" << STUBA
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_DIR/attest-args"
for a in "\$@"; do case "\$a" in --out=*) printf '{}' > "\${a#--out=}";; esac; done
STUBA
    chmod +x "$STUB_BIN/wrangle-attest"
    # shellcheck source=sign_metadata.sh
    source "$SIGN"
    PATH="$STUB_BIN:$PATH" wrangle_sign_metadata_statements "dist/app-1.2.3.tgz" "/tmp/out.jsonl"
    grep -qx -- "--artifact=dist/app-1.2.3.tgz" "$TEST_DIR/attest-args"
    grep -qx -- "--sign" "$TEST_DIR/attest-args"
    grep -qx -- "--out=/tmp/out.jsonl" "$TEST_DIR/attest-args"
}

@test "sign_metadata: bnd push targets the GitHub store by repo" {
    # shellcheck source=sign_metadata.sh
    source "$SIGN"
    mapfile -t args < <(wrangle_bnd_push_args "o/r" "/tmp/stmt.json")
    [ "${args[0]}" = push ]
    [ "${args[1]}" = github ]
    [ "${args[2]}" = "o/r" ]
    [ "${args[3]}" = "/tmp/stmt.json" ]
}

@test "sign_metadata: attest args carry the metadata-root, subject arg, commit, sign, and out" {
    export METADATA_ROOT="$TEST_DIR/meta" COMMIT="deadbeef"
    # shellcheck source=sign_metadata.sh
    source "$SIGN"
    mapfile -t args < <(wrangle_attest_args "--subject=sha256:abc" "$TEST_DIR/out.jsonl")
    printf '%s\n' "${args[@]}" | grep -qx -- "--metadata-root=$TEST_DIR/meta"
    printf '%s\n' "${args[@]}" | grep -qx -- "--subject=sha256:abc"
    printf '%s\n' "${args[@]}" | grep -qx -- "--commit=deadbeef"
    printf '%s\n' "${args[@]}" | grep -qx -- "--sign"
    printf '%s\n' "${args[@]}" | grep -qx -- "--out=$TEST_DIR/out.jsonl"
}

@test "sign_metadata: attest args pass an --artifact subject arg through verbatim" {
    export METADATA_ROOT="$TEST_DIR/meta"
    # shellcheck source=sign_metadata.sh
    source "$SIGN"
    mapfile -t args < <(wrangle_attest_args "--artifact=$TEST_DIR/dist/a.tgz" "$TEST_DIR/out.jsonl")
    printf '%s\n' "${args[@]}" | grep -qx -- "--artifact=$TEST_DIR/dist/a.tgz"
}

@test "sign_metadata: attest arg vector is accepted by the real wrangle-attest parser" {
    # The real engine rejects an unknown flag; a run that gets past flag parsing
    # (failing later on the bogus subject/root) proves every flag name matches.
    [[ -x "$ATTEST_BIN" ]] || skip_or_fail "wrangle-attest not built"
    export METADATA_ROOT="$TEST_DIR/meta"
    # shellcheck source=sign_metadata.sh
    source "$SIGN"
    mapfile -t args < <(wrangle_attest_args "--subject=sha256:abc" "$TEST_DIR/out.jsonl")
    run "$ATTEST_BIN" "${args[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" != *"flag provided but not defined"* ]]
}

# ---- end-to-end with real wrangle-attest (unsigned-statement variant via stub bnd) ----
# wrangle-attest --sign needs OIDC; to exercise the per-subject statement +
# assembly + push plumbing offline we drive the real engine without --sign by
# stubbing it to emit the unsigned statement, and stub bnd to record the push.

@test "sign_metadata: signs every subject's metadata and assembles its bundle" {
    [[ -x "$ATTEST_BIN" ]] || skip_or_fail "wrangle-attest not built"
    stub_bnd
    # A wrapper that forwards to the real engine but drops --sign (offline).
    cat > "$STUB_BIN/wrangle-attest" << STUBA
#!/usr/bin/env bash
set -euo pipefail
args=()
for a in "\$@"; do [[ "\$a" == "--sign" ]] || args+=("\$a"); done
exec "$ATTEST_BIN" "\${args[@]}"
STUBA
    chmod +x "$STUB_BIN/wrangle-attest"

    printf '{"provenance":1}\n' > "$TEST_DIR/provenance.jsonl"
    PATH="$STUB_BIN:$PATH" SUBJECTS="$DIST/app-1.2.3.tgz" METADATA_ROOT="$META" \
        BUNDLE_IN="$TEST_DIR/provenance.jsonl" BUNDLE_OUT="$TEST_DIR/bundles" \
        GITHUB_REPOSITORY="o/r" COMMIT="abc123" run "$SIGN"
    [ "$status" -eq 0 ]
    # One per-artifact bundle (provenance seed + signed metadata) and one push.
    local bundle="$TEST_DIR/bundles/app-1.2.3.tgz.intoto.jsonl"
    [ -s "$bundle" ]
    [ "$(head -n1 "$bundle")" = '{"provenance":1}' ]
    [ "$(wc -l < "$PUSH_RECORD")" -eq 1 ]
    grep -q '^o/r ' "$PUSH_RECORD"
}

# ---- real-engine statement emission + fail-closed ----

@test "sign_metadata: the real engine emits the in-toto statement in unsigned mode" {
    # Happy path against the real binary, hermetically: unsigned mode needs no
    # OIDC/network, so it proves end-to-end manifest -> in-toto statement.
    [[ -x "$ATTEST_BIN" ]] || skip_or_fail "wrangle-attest not built"
    local out="$TEST_DIR/out.intoto.jsonl"
    local sha; sha="$(printf '0%.0s' {1..64})"
    run "$ATTEST_BIN" --metadata-root="$META" --subject="sha256:$sha" --out="$out"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$out")" -eq 1 ]
    [ "$(jq -r '.predicateType' "$out")" = "https://spdx.dev/Document" ]
    [ "$(jq -r '.subject[0].digest.sha256' "$out")" = "$sha" ]
}

@test "sign_metadata: fails closed when the real engine sees a malformed manifest" {
    # The real engine fails closed at discoverManifests — before newSigner — so a
    # malformed top-level manifest aborts hermetically (no OIDC/network).
    [[ -x "$ATTEST_BIN" ]] || skip_or_fail "wrangle-attest not built"
    local dir="$TEST_DIR/wrangle-attest-bin"; mkdir -p "$dir"
    ln -sf "$ATTEST_BIN" "$dir/wrangle-attest"
    local root="$TEST_DIR/badmeta"; mkdir -p "$root"
    printf 'not json\n' > "$root/wrangle_attestation_metadata.json"
    # shellcheck source=sign_metadata.sh
    source "$SIGN"
    PATH="$dir:$PATH" METADATA_ROOT="$root" WRANGLE_RETRY_DELAY=0 \
        run wrangle_sign_metadata_statements "sha256:$(printf '0%.0s' {1..64})" "$TEST_DIR/out.jsonl"
    [ "$status" -ne 0 ]
}

# ---- M4: attest binds the SAME subject digest the verify VSA binds ----

@test "sign_metadata: attest subject digest equals the verify subject digest (M4)" {
    [[ -x "$ATTEST_BIN" ]] || skip_or_fail "wrangle-attest not built"
    # Attest side: wrangle-attest self-digests the dist file into the statement.
    "$ATTEST_BIN" --metadata-root="$META" --artifact="$DIST/app-1.2.3.tgz" \
        --out="$TEST_DIR/stmt.jsonl"
    attest_digest="$(jq -r '.subject[0].digest.sha256' "$TEST_DIR/stmt.jsonl" | head -1)"

    # Verify side: run_verify.sh wrangle_subject_arg hashes the same file.
    # shellcheck source=../verify/run_verify.sh
    source "$REPO_ROOT/actions/verify/run_verify.sh"
    verify_arg="$(wrangle_subject_arg "$DIST/app-1.2.3.tgz")"
    verify_digest="${verify_arg#--subject-hash=sha256:}"

    [ -n "$attest_digest" ]
    [ "$attest_digest" = "$verify_digest" ]
}
