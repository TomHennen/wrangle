#!/usr/bin/env bats

# Tests for actions/verify/run_verify.sh
#
# The arg-builder functions are validated against the shape the real
# wrangle-attest/bnd/cosign CLIs accept. Full keyless signing needs OIDC and
# cannot run offline, so the verify path is exercised end-to-end with a tiny
# wrangle-attest stub on PATH that honors the engine's verify contract (signed
# line at --out, appended to --bundle, report on stdout); the engine's own
# verdict protocol is covered by go test ./wrangle-attest/. bnd/cosign stubs
# cover the push plumbing (verify appends the VSA to the attest-assembled
# bundle; assembly itself is tested in test/test_sign_metadata.bats).
#
# skip_or_fail (fail-not-skip under CI) lives in a shared bats helper. The real
# ampel/bnd/cosign/wrangle-attest are installed only in the `integration (real
# binaries)` job, so a skip there means coverage silently degraded; the unit
# suite has no real binaries and skips these by design.
load "../../test/lib/bats_helpers"

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/run_verify.sh"
    TEST_DIR="$(mktemp -d)"

    # Discover the real tools wherever they're installed (PATH or the action's
    # WRANGLE_BIN_DIR), so the integration assertions actually run in any job
    # that built the tools and skip only when they're genuinely absent.
    AMPEL_BIN="$(command -v ampel || echo "${WRANGLE_BIN_DIR:-/nonexistent}/ampel")"
    BND_BIN="$(command -v bnd || echo "${WRANGLE_BIN_DIR:-/nonexistent}/bnd")"
    COSIGN_BIN="$(command -v cosign || echo "${WRANGLE_BIN_DIR:-/nonexistent}/cosign")"
    WATTEST_BIN="$(command -v wrangle-attest || echo "${WRANGLE_BIN_DIR:-/nonexistent}/wrangle-attest")"

    export SUBJECTS=$'dist/app-1.2.3.tgz'
    export POLICY="policies/release.json"
    # Empty for go/npm/python (the bundle is the only collector); container sets oci:.
    export COLLECTOR=""
    export FAIL="true"
    export CONTEXT=""
    export ATTESTATION=""
    export OCI_TARGET=""
    # bundle-in is the directory of attest-assembled bundles verify appends the VSA to.
    export BUNDLE_IN="$TEST_DIR/in"
    mkdir -p "$BUNDLE_IN"
    # bundle-out is the directory the completed bundles are written into.
    export BUNDLE_OUT="$TEST_DIR/bundles"
    export GITHUB_REPOSITORY="o/r"
    export RUNNER_TEMP="$TEST_DIR"
    # The unsigned-VSA path the arg-vector tests reference.
    VSA="$TEST_DIR/vsa.intoto.jsonl"
    # No real Sigstore here, so the inter-attempt backoff is pure dead time.
    export WRANGLE_RETRY_DELAY=0

    # shellcheck source=run_verify.sh
    source "$SCRIPT"
    # wrangle_engine_verify uses wrangle_sanitize_output, which run() sources
    # at runtime; load it here so the direct-call report tests have it too.
    # shellcheck source=../../lib/sanitize.sh
    source "$(cd "$(dirname "$BATS_TEST_FILENAME")/../../lib" && pwd)/sanitize.sh"
    # Signing/verify always containerizes; make the toolbox path transparent so
    # orchestration tests exercise their tool stubs. Recording-docker tests override.
    wrangle_stub_toolbox_transparent
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "run_verify: exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "run_verify: a policy locator passes through unresolved" {
    export POLICY="git+https://github.com/o/r@abc123#policies/x.hjson"
    mapfile -t args < <(wrangle_engine_verify_args "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl")
    printf '%s\n' "${args[@]}" | grep -qx -- "--policy=git+https://github.com/o/r@abc123#policies/x.hjson"
}

@test "run_verify: an absolute policy path passes through unresolved" {
    # The absolute-path arm fails SILENTLY if dropped (an absolute path would be
    # double-prefixed to $REPO_ROOT/abs/… and ampel would read the wrong file),
    # so it gets its own guard distinct from the locator case.
    export POLICY="/etc/wrangle/policy.hjson"
    mapfile -t args < <(wrangle_engine_verify_args "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl")
    printf '%s\n' "${args[@]}" | grep -qx -- "--policy=/etc/wrangle/policy.hjson"
}

# --- engine arg vector ---

@test "run_verify: engine args carry the core verify flags for the given subject" {
    mapfile -t args < <(wrangle_engine_verify_args "sha256:abc123" "$VSA" "$TEST_DIR/b.jsonl")
    [[ "${args[0]}" == "verify" ]]
    printf '%s\n' "${args[@]}" | grep -qx -- "--subject=sha256:abc123"
    # The bundle rides --bundle: the engine feeds it to the policy as the
    # jsonl: collector AND appends the signed VSA to it.
    printf '%s\n' "${args[@]}" | grep -qx -- "--bundle=$TEST_DIR/b.jsonl"
    # A relative policy path is resolved to an absolute path under the action's checkout.
    printf '%s\n' "${args[@]}" | grep -qE -- "^--policy=/.*/policies/release\.json$"
    printf '%s\n' "${args[@]}" | grep -qx -- "--fail=true"
    printf '%s\n' "${args[@]}" | grep -qx -- "--out=$VSA"
}

@test "run_verify: engine args pass a file subject as --artifact for the engine to self-digest" {
    # The store rejects a multi-digest subject; the engine self-digests the
    # file to the single sha256 and hands ampel a precomputed --subject-hash.
    mapfile -t args < <(wrangle_engine_verify_args "$TEST_DIR/dist/app.tgz" "$VSA" "$TEST_DIR/b.jsonl")
    printf '%s\n' "${args[@]}" | grep -qx -- "--artifact=$TEST_DIR/dist/app.tgz"
    if printf '%s\n' "${args[@]}" | grep -q -- "--subject="; then return 1; fi
}

@test "run_verify: engine args omit collector, context, and attestation when empty" {
    mapfile -t args < <(wrangle_engine_verify_args "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl")
    if printf '%s\n' "${args[@]}" | grep -q -- "--collector"; then return 1; fi
    if printf '%s\n' "${args[@]}" | grep -q -- "--context"; then return 1; fi
    if printf '%s\n' "${args[@]}" | grep -q -- "--attestation"; then return 1; fi
}

@test "run_verify: engine args include collector, context, and attestation when set" {
    # Container: COLLECTOR (the oci: referrer collector) is additional — the
    # engine always feeds the bundle itself as the jsonl: collector.
    export COLLECTOR="oci:registry.example/img@sha256:abc"
    export CONTEXT="buildPoint:git+https://github.com/o/r"
    export ATTESTATION="att.intoto.json"
    mapfile -t args < <(wrangle_engine_verify_args "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl")
    printf '%s\n' "${args[@]}" | grep -qx -- "--collector=$COLLECTOR"
    printf '%s\n' "${args[@]}" | grep -qx -- "--context=$CONTEXT"
    printf '%s\n' "${args[@]}" | grep -qx -- "--attestation=$ATTESTATION"
}

@test "run_verify: engine args carry fail=false through (warn mode)" {
    export FAIL="false"
    mapfile -t args < <(wrangle_engine_verify_args "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl")
    printf '%s\n' "${args[@]}" | grep -qx -- "--fail=false"
}

@test "run_verify: engine arg vector drives the real engine into the real ampel" {
    # End-to-end over the exec seam with the real binaries: the engine parses
    # our vector, execs the real ampel (a bogus policy makes it fail after flag
    # parsing), and reports the ampel failure — so any flag drift would surface
    # as "not defined" (engine) or "unknown flag" (ampel) instead.
    if [[ ! -x "$WATTEST_BIN" || ! -x "$AMPEL_BIN" ]]; then skip_or_fail "real wrangle-attest/ampel not available"; fi
    export POLICY="$TEST_DIR/no-such-policy.hjson"
    printf '{"provenance":1}\n' > "$TEST_DIR/b.jsonl"
    local sha; sha="$(printf '0%.0s' {1..64})"
    mapfile -t args < <(wrangle_engine_verify_args "sha256:$sha" "$TEST_DIR/vsa.out" "$TEST_DIR/b.jsonl")
    PATH="$(dirname "$AMPEL_BIN"):$PATH" WRANGLE_RETRY_DELAY=0 run "$WATTEST_BIN" "${args[@]}"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"ampel verify failed"* ]]
    [[ "$output" != *"not defined"* ]]
    [[ "$output" != *"unknown flag"* ]]
    [[ "$output" != *"unknown shorthand"* ]]
}

# --- cosign arg vectors (VSA referrer push) ---

@test "run_verify: cosign attach args push the VSA file as an attestation referrer" {
    local target="ghcr.io/o/r/img@sha256:abc"
    local vsa="$TEST_DIR/vsa-line.jsonl"
    mapfile -t args < <(wrangle_cosign_attach_args "$vsa" "$target")
    [[ "${args[0]}" == "attach" ]]
    [[ "${args[1]}" == "attestation" ]]
    # --attestation carries the single VSA statement; the image ref is positional.
    printf '%s\n' "${args[@]}" | grep -qx -- "--attestation"
    printf '%s\n' "${args[@]}" | grep -qx -- "$vsa"
    [[ "${args[-1]}" == "$target" ]]
    # `attach attestation` uploads verbatim (no re-sign), so no --type/--yes/key flags.
    ! printf '%s\n' "${args[@]}" | grep -qx -- "--type"
}

@test "run_verify: cosign attach arg vector names a real cosign subcommand" {
    if [[ ! -x "$COSIGN_BIN" ]]; then skip_or_fail "real cosign not available"; fi
    # `cosign attach attestation --help` proves the verb exists and that
    # --attestation is a real flag, without contacting a registry.
    run "$COSIGN_BIN" attach attestation --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--attestation"* ]]
    [[ "$output" == *"attach attestation"* ]]
}

# --- bnd push arg vector (GitHub attestation store) ---

@test "run_verify: bnd push arg vector names a real bnd subcommand" {
    if [[ ! -x "$BND_BIN" ]]; then skip_or_fail "real bnd not available"; fi
    run "$BND_BIN" push github --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GitHub attestation store"* ]]
}

# --- subject parsing ---

@test "run_verify: read_subjects splits the newline list and drops blanks" {
    export SUBJECTS=$'dist/a.tgz\n\ndist/b.whl\n'
    local -a WRANGLE_SUBJECTS
    wrangle_read_subjects
    [[ "${#WRANGLE_SUBJECTS[@]}" -eq 2 ]]
    [[ "${WRANGLE_SUBJECTS[0]}" == "dist/a.tgz" ]]
    [[ "${WRANGLE_SUBJECTS[1]}" == "dist/b.whl" ]]
}

@test "run_verify: read_subjects fails closed on an empty subject set" {
    # A VSA-less bundle would silently drop the release-gating verification.
    export SUBJECTS=$'\n  \n'
    local -a WRANGLE_SUBJECTS
    run wrangle_read_subjects
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no subjects"* ]]
}

# Emit a signed metadata JSONL line: a DSSE bundle whose decoded payload
# binds subject sha256 $1 and predicateType $2 — the shape the attest job's
# assembled bundle carries.
_signed_meta_line() {
    local payload
    payload="$(printf '{"predicateType":"%s","subject":[{"digest":{"sha256":"%s"}}]}' "$2" "$1" | base64 | tr -d '\n')"
    printf '{"dsseEnvelope":{"payload":"%s"}}\n' "$payload"
}

# --- push bundle ---

@test "run_verify: push is a no-op when OCI_TARGET is empty" {
    # npm/go/python path: nothing on PATH should be invoked. A cosign stub that
    # fails proves push returns 0 without calling it.
    cat > "$TEST_DIR/cosign" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$TEST_DIR/cosign"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET=""
    run wrangle_push_bundle "$TEST_DIR/vsa-line.jsonl"
    [[ "$status" -eq 0 ]]
}

@test "run_verify: push invokes cosign attach with the VSA file and OCI target" {
    cat > "$TEST_DIR/cosign" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$TEST_DIR/cosign-args"
STUB
    chmod +x "$TEST_DIR/cosign"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:abc"
    local vsa="$TEST_DIR/vsa-line.jsonl"
    : > "$vsa"
    run wrangle_push_bundle "$vsa"
    [[ "$status" -eq 0 ]]
    recorded="$(cat "$TEST_DIR/cosign-args")"
    [[ "$recorded" == *"attach"* ]]
    [[ "$recorded" == *"attestation"* ]]
    [[ "$recorded" == *"$vsa"* ]]
    [[ "$recorded" == *"$OCI_TARGET"* ]]
}

@test "run_verify: push fails closed — a cosign failure fails the step" {
    # The by-digest VSA referrer is the path the container consumer verifies, so
    # a push failure is a real delivery gap and must fail the job (after the one
    # transient-Sigstore retry, so cosign is invoked twice).
    cat > "$TEST_DIR/cosign" <<STUB
#!/bin/bash
printf 'x\n' >> "$TEST_DIR/cosign-calls"
exit 7
STUB
    chmod +x "$TEST_DIR/cosign"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:abc"
    : > "$TEST_DIR/cosign-calls"
    local vsa="$TEST_DIR/vsa-line.jsonl"
    : > "$vsa"
    run wrangle_push_bundle "$vsa"
    [[ "$status" -ne 0 ]]
    [[ "$(wc -l < "$TEST_DIR/cosign-calls")" -eq 2 ]]
}

# --- push to GitHub attestation store ---

@test "run_verify: push_store invokes bnd push github with the repo and VSA file" {
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$TEST_DIR/bnd-args"
STUB
    chmod +x "$TEST_DIR/bnd"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_REPOSITORY="owner/repo"
    local vsa="$TEST_DIR/vsa.jsonl"
    : > "$vsa"
    run wrangle_push_store "$vsa"
    [[ "$status" -eq 0 ]]
    recorded="$(cat "$TEST_DIR/bnd-args")"
    [[ "$recorded" == *"push"* ]]
    [[ "$recorded" == *"github"* ]]
    [[ "$recorded" == *"owner/repo"* ]]
    [[ "$recorded" == *"$vsa"* ]]
}

@test "run_verify: push_store fails closed — a bnd failure fails the step" {
    # The store is the by-digest delivery, so a push failure is a real delivery
    # gap and must fail the job (after the one transient retry, so bnd runs twice).
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
printf 'x\n' >> "$TEST_DIR/bnd-calls"
exit 7
STUB
    chmod +x "$TEST_DIR/bnd"
    export PATH="$TEST_DIR:$PATH"
    : > "$TEST_DIR/bnd-calls"
    local vsa="$TEST_DIR/vsa.jsonl"
    : > "$vsa"
    run wrangle_push_store "$vsa"
    [[ "$status" -ne 0 ]]
    [[ "$(wc -l < "$TEST_DIR/bnd-calls")" -eq 2 ]]
}

# --- emit path plumbing (stubbed ampel) ---

@test "run_verify: the engine report pipes through the HTML sanitizer to the summary" {
    # Stub engine emits HTML (ampel's report passes through its stdout) so we
    # can confirm tags are stripped on the way to the summary.
    cat > "$TEST_DIR/wrangle-attest" <<'STUB'
#!/bin/bash
printf '<h1>PASS</h1><script>x</script>RESULT\n'
STUB
    chmod +x "$TEST_DIR/wrangle-attest"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"

    run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [[ "$status" -eq 0 ]]
    summary="$(cat "$GITHUB_STEP_SUMMARY")"
    [[ "$summary" == *"PASS"* ]]
    [[ "$summary" == *"RESULT"* ]]
    [[ "$summary" != *"<h1>"* ]]
    [[ "$summary" != *"<script>"* ]]
}

@test "run_verify: a PASS verdict survives a report exceeding the summary cap" {
    # Regression: a >MAX_SUMMARY report must not SIGPIPE the engine and flip
    # a passing verdict into a blocked release.
    cat > "$TEST_DIR/wrangle-attest" <<'STUB'
#!/bin/bash
head -c 200000 /dev/zero | tr '\0' 'a'
exit 0
STUB
    chmod +x "$TEST_DIR/wrangle-attest"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"

    run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [[ "$status" -eq 0 ]]
    # Summary is truncated to the cap, but the verdict still passed.
    [[ "$(wc -c < "$GITHUB_STEP_SUMMARY")" -le 65536 ]]
}

@test "run_verify: a failing engine exit code propagates and echoes the report to the log" {
    cat > "$TEST_DIR/wrangle-attest" <<'STUB'
#!/bin/bash
printf 'FAILED-REPORT\n'
exit 1
STUB
    chmod +x "$TEST_DIR/wrangle-attest"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"

    run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [[ "$status" -ne 0 ]]
    # The failed report is echoed to the job log, not just the easy-to-miss summary.
    [[ "$output" == *"verification failed for sha256:abc"* ]]
    [[ "$output" == *"FAILED-REPORT"* ]]
}

@test "run_verify: run rejects an input that fails validation (fail-closed)" {
    # Run the SCRIPT (set -e active) so a bad input hard-fails at validation
    # before ampel — `run <function>` would disable errexit and fall through.
    export SUBJECTS='bad;rm -rf /'
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    run "$SCRIPT" run
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid subject"* ]]
    [[ "$output" != *"command not found"* ]]
}

# --- run composition: per-subject verify -> sign -> append VSA ---

# Stage subject $1's attest-assembled bundle (provenance + signed metadata) at
# BUNDLE_IN/<name>, as the attest job emits it for verify to append the VSA to.
_stage_bundle() {
    local name="$1" sha="$2"
    {
        printf '{"provenance":1}\n'
        _signed_meta_line "$sha" "https://spdx.dev/Document"
    } > "$BUNDLE_IN/$name"
}

# A wrangle-attest stub honoring the engine's verify contract: the signed VSA
# line (echoing back the subject digest so tests can prove which subject
# reached the bundle and the store) lands at --out AND is appended to --bundle;
# the report goes to stdout. Records every argv in $TEST_DIR/engine-args. The
# real engine can't run here (keyless signing needs OIDC/network); its verdict
# protocol is covered by go test ./wrangle-attest/.
_stub_engine_verify() {
    cat > "$TEST_DIR/wrangle-attest" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >> "$TEST_DIR/engine-args"
[[ "\$1" == "verify" ]] || { echo "non-verify engine invocation: \$1" >&2; exit 97; }
subj="" out="" bundle=""
for a in "\$@"; do case "\$a" in
    --subject=*)  subj="\${a#--subject=}" ;;
    --artifact=*) subj="sha256:\$(sha256sum "\${a#--artifact=}" | cut -d' ' -f1)" ;;
    --out=*)      out="\${a#--out=}" ;;
    --bundle=*)   bundle="\${a#--bundle=}" ;;
esac; done
printf '{"signed":{"unsigned":"%s"}}\n' "\$subj" > "\$out"
cat "\$out" >> "\$bundle"
printf 'report\n'
STUB
    chmod +x "$TEST_DIR/wrangle-attest"
    : > "$TEST_DIR/engine-args"
}

@test "run_verify: run verifies, signs, and appends one VSA line per subject" {
    # Stub the engine so each subject produces a deterministic signed line; the
    # completed bundle = the attest-assembled bundle plus one appended VSA.
    _stub_engine_verify
    # bnd handles only the store push; VSA signing never reaches it.
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
[[ "\$1" == "push" ]] || { echo "unexpected bnd verb: \$1" >&2; exit 96; }
cat "\$4" >> "$TEST_DIR/pushed"
STUB
    chmod +x "$TEST_DIR/bnd"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    : > "$TEST_DIR/pushed"
    # Real file subjects: run_verify sha256-hashes each into a single-digest
    # --subject-hash, so the VSA's subject can't carry two digests (the store
    # rejects that). Distinct bytes -> distinct digests the assertions key on.
    mkdir -p "$TEST_DIR/dist"
    printf 'AAA\n' > "$TEST_DIR/dist/a.tgz"
    printf 'BBB\n' > "$TEST_DIR/dist/b.whl"
    local ha hb
    ha="sha256:$(sha256sum "$TEST_DIR/dist/a.tgz" | cut -d' ' -f1)"
    hb="sha256:$(sha256sum "$TEST_DIR/dist/b.whl" | cut -d' ' -f1)"
    export SUBJECTS="$TEST_DIR/dist/a.tgz"$'\n'"$TEST_DIR/dist/b.whl"
    _stage_bundle "a.tgz.intoto.jsonl" "${ha#sha256:}"
    _stage_bundle "b.whl.intoto.jsonl" "${hb#sha256:}"

    run "$SCRIPT" run
    [[ "$status" -eq 0 ]]
    # One completed bundle per subject, named <artifact-basename>.intoto.jsonl.
    local a="$BUNDLE_OUT/a.tgz.intoto.jsonl" b="$BUNDLE_OUT/b.whl.intoto.jsonl"
    [[ -f "$a" && -f "$b" ]]
    # Each subject's signed VSA (keyed by its sha256) was posted to the store.
    grep -q "\"signed\":{\"unsigned\":\"$ha\"}" "$TEST_DIR/pushed"
    grep -q "\"signed\":{\"unsigned\":\"$hb\"}" "$TEST_DIR/pushed"
    # Each bundle is the attest-assembled lines (provenance + metadata) plus the VSA.
    [[ "$(wc -l < "$a")" -eq 3 ]]
    [[ "$(wc -l < "$b")" -eq 3 ]]
    run head -n1 "$a"; [[ "$output" == '{"provenance":1}' ]]
    grep -q "\"signed\":{\"unsigned\":\"$ha\"}" "$a"
    grep -q "\"signed\":{\"unsigned\":\"$hb\"}" "$b"
    # A subject's bundle carries only its own VSA, not the other's.
    ! grep -q "$hb" "$a"
    ! grep -q "$ha" "$b"
    # Every line is one JSON object (valid JSONL).
    run jq -e . "$a"; [[ "$status" -eq 0 ]]
    run jq -e . "$b"; [[ "$status" -eq 0 ]]
}

@test "run_verify: run hands the engine the attest-assembled bundle, verify-mode only" {
    # The bundle (provenance + signed SBOM/scan) rides --bundle so the engine
    # feeds it to the policy and appends the VSA to it. Every engine invocation
    # must be verify-mode (the stub hard-fails otherwise), proving verify never
    # re-signs metadata via manifest/assemble mode.
    _stub_engine_verify
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
[[ "\$1" == "push" ]] || { echo "unexpected bnd verb: \$1" >&2; exit 96; }
cat "\$4" >> "$TEST_DIR/pushed"
STUB
    chmod +x "$TEST_DIR/bnd"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"; : > "$GITHUB_STEP_SUMMARY"
    : > "$TEST_DIR/pushed"
    export OCI_TARGET=""
    local sha; sha="$(printf '0%.0s' {1..64})"
    export SUBJECTS="sha256:$sha"
    _stage_bundle "sha256-$sha.intoto.jsonl" "$sha"

    run "$SCRIPT" run
    [[ "$status" -eq 0 ]]
    # The engine was handed the completed-bundle path under BUNDLE_OUT.
    grep -qE -- "^--bundle=$BUNDLE_OUT/" "$TEST_DIR/engine-args"
    # The attest-signed metadata statement is preserved in the completed bundle.
    local bundle; bundle="$BUNDLE_OUT/$(ls "$BUNDLE_OUT")"
    grep -q '"dsseEnvelope"' "$bundle"
    [[ "$(grep '"dsseEnvelope"' "$bundle" | jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicateType')" == "https://spdx.dev/Document" ]]
    # verify did NOT re-push the metadata to the store — only the VSA was pushed.
    [[ "$(wc -l < "$TEST_DIR/pushed")" -eq 1 ]]
    ! grep -q 'dsseEnvelope' "$TEST_DIR/pushed"
}

@test "run_verify: run fails closed when a subject's attest-assembled bundle is missing" {
    # The attest job must have assembled this subject's bundle; a missing one is a
    # wiring/attest bug and must abort rather than emit a VSA-only bundle.
    cat > "$TEST_DIR/wrangle-attest" <<'STUB'
#!/bin/bash
echo "engine must not run without a staged bundle" >&2
exit 1
STUB
    chmod +x "$TEST_DIR/wrangle-attest"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"; : > "$GITHUB_STEP_SUMMARY"
    local sha; sha="$(printf '0%.0s' {1..64})"
    export SUBJECTS="sha256:$sha"
    # BUNDLE_IN holds no bundle for this subject.
    run "$SCRIPT" run
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"missing or empty"* ]]
    [[ "$output" != *"engine must not run"* ]]
}

@test "run_verify: run pushes only the VSA statement as the referrer for an OCI target" {
    # Container path: the attest-assembled bundle is appended with the VSA for the
    # workflow artifact, but only the lone signed VSA statement is pushed as the
    # by-digest referrer (cosign attach rejects a multi-line bundle).
    _stub_engine_verify
    cat > "$TEST_DIR/bnd" <<'STUB'
#!/bin/bash
[[ "$1" == "push" ]] && exit 0
exit 96
STUB
    # Record the attach file so the test can prove it was the single VSA statement.
    {
        printf '#!/bin/bash\n'
        printf 'printf "%%s\\n" "$1" >> %q\n' "$TEST_DIR/cosign-calls"
        printf 'if [[ "$1" == "attach" ]]; then\n'
        printf '  for a in "$@"; do prev="${prev:-}"; [[ "$prev" == "--attestation" ]] && cp "$a" %q; prev="$a"; done\n' "$TEST_DIR/attached"
        printf 'fi\n'
        printf 'exit 0\n'
    } > "$TEST_DIR/cosign"
    chmod +x "$TEST_DIR/bnd" "$TEST_DIR/cosign"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    local sha; sha="$(printf '0%.0s' {1..64})"
    export SUBJECTS="sha256:$sha"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:$sha"
    _stage_bundle "sha256-$sha.intoto.jsonl" "$sha"

    run "$SCRIPT" run
    [[ "$status" -eq 0 ]]
    # cosign was called to attach the VSA (verify no longer downloads — attest seeded).
    grep -qx "attach" "$TEST_DIR/cosign-calls"
    ! grep -qx "download" "$TEST_DIR/cosign-calls"
    # The completed bundle = provenance line + metadata line + VSA line.
    local bundle="$BUNDLE_OUT/sha256-$sha.intoto.jsonl"
    [[ -f "$bundle" ]]
    [[ "$(wc -l < "$bundle")" -eq 3 ]]
    # The referrer push got ONLY the lone VSA statement — a single line, no
    # provenance — so cosign attach accepts it.
    [[ "$(wc -l < "$TEST_DIR/attached")" -eq 1 ]]
    grep -q "\"signed\":{\"unsigned\":\"sha256:$sha\"}" "$TEST_DIR/attached"
    ! grep -q 'dsseEnvelope' "$TEST_DIR/attached"
}

@test "run_verify: run fails closed when the VSA referrer push fails" {
    # The by-digest VSA referrer is the container consumer's discovery path, so a
    # failing cosign attach (after the one transient retry) must fail the verify
    # job — a missing by-digest VSA is a real delivery gap, not a nice-to-have.
    _stub_engine_verify
    cat > "$TEST_DIR/bnd" <<'STUB'
#!/bin/bash
[[ "$1" == "push" ]] && exit 0
exit 96
STUB
    cat > "$TEST_DIR/cosign" <<'STUB'
#!/bin/bash
[[ "$1" == "attach" ]] && exit 7
exit 0
STUB
    chmod +x "$TEST_DIR/bnd" "$TEST_DIR/cosign"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    local sha; sha="$(printf '0%.0s' {1..64})"
    export SUBJECTS="sha256:$sha"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:$sha"
    _stage_bundle "sha256-$sha.intoto.jsonl" "$sha"

    run "$SCRIPT" run
    [[ "$status" -ne 0 ]]
}

# --- attach to release (wrangle_attach_release) ---
#
# wrangle drives a draft -> attach-all -> publish flow: it creates the tag's
# release as a draft if absent, uploads assets, then flips it to published. These
# tests drive a `gh` shim whose `release view` existence-probe exit code follows
# GH_VIEW_SEQ so both branches (release present / absent) are exercised.

# Install a gh shim on PATH that logs calls and returns scripted exit codes.
_install_gh_shim() {
    cat > "$TEST_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "release view")
    # The --json reads (body for the unattested marker, isDraft for the
    # publish-flip fallback) are separate from the existence probe: serve the
    # staged value and never consume a GH_VIEW_SEQ slot.
    if [[ "$*" == *"--json body"* ]]; then cat "${GH_BODY:-/dev/null}"; exit 0; fi
    if [[ "$*" == *"--json isDraft"* ]]; then printf '%s' "${GH_ISDRAFT:-false}"; exit 0; fi
    n=$(cat "$GH_VIEW_N" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$GH_VIEW_N"
    code=$(printf '%s' "$GH_VIEW_SEQ" | cut -d' ' -f"$n"); exit "${code:-1}" ;;
  "release create") exit "${GH_CREATE_CODE:-0}" ;;
  "release edit")
    # Capture the --notes value (the new body) so tests can assert what was set.
    prev=""; for a in "$@"; do [[ "$prev" == "--notes" ]] && printf '%s' "$a" > "${GH_NOTES:-/dev/null}"; prev="$a"; done
    exit "${GH_EDIT_CODE:-0}" ;;
  "release upload")
    [[ -n "${GH_KEEP_ZIP:-}" && "$4" == *.zip ]] && cp "$4" "$GH_KEEP_ZIP"
    # GH_ZIP_UPLOAD_CODE fails only the metadata-zip upload, leaving dist/bundle
    # uploads green — isolates the last-asset failure that must abort the flip.
    [[ "$4" == *.zip ]] && exit "${GH_ZIP_UPLOAD_CODE:-0}"
    exit "${GH_UPLOAD_CODE:-0}" ;;
esac
exit 0
SHIM
    chmod +x "$TEST_DIR/gh"
    export PATH="$TEST_DIR:$PATH"
    export GH_LOG="$TEST_DIR/gh.log"; : > "$GH_LOG"
    export GH_VIEW_N="$TEST_DIR/gh.viewn"; : > "$GH_VIEW_N"
    export GITHUB_REF_NAME="v1.2.3"
}

# Stage the metadata dir (bundles + sbom) + a dist dir whose <artifact> files
# match each bundle's <artifact>.intoto.jsonl name, plus the env the attach
# reads. Production wires bundle-out and metadata-dir to the same dir, so the
# sbom (and the metadata zip's other contents) live under METADATA_ROOT.
_stage_release_assets() {
    export METADATA_ROOT="$BUNDLE_OUT"
    mkdir -p "$BUNDLE_OUT" "$TEST_DIR/dist"
    : > "$BUNDLE_OUT/a.tgz.intoto.jsonl"
    : > "$BUNDLE_OUT/b.whl.intoto.jsonl"
    : > "$METADATA_ROOT/sbom.spdx.json"
    : > "$TEST_DIR/dist/a.tgz"
    : > "$TEST_DIR/dist/b.whl"
    export DIST_DIR="$TEST_DIR/dist"
    export METADATA_ZIP_NAME="python-metadata.zip"
}

# zip is the only external command the metadata-zip step needs that the unit
# host may lack; gate the asserts that exercise it.
_require_zip() {
    command -v zip >/dev/null 2>&1 || skip_or_fail "zip not installed"
}

@test "run_verify attach: per subject uploads the dist artifact and its bundle, plus one metadata zip" {
    _require_zip
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="python"
    export GH_VIEW_SEQ="0"            # release exists
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    grep -qx "release upload v1.2.3 $BUNDLE_OUT/a.tgz.intoto.jsonl --clobber" "$GH_LOG"
    grep -qx "release upload v1.2.3 $BUNDLE_OUT/b.whl.intoto.jsonl --clobber" "$GH_LOG"
    grep -qx "release upload v1.2.3 $DIST_DIR/a.tgz --clobber" "$GH_LOG"
    grep -qx "release upload v1.2.3 $DIST_DIR/b.whl --clobber" "$GH_LOG"
    grep -q "release upload v1.2.3 .*python-metadata.zip --clobber" "$GH_LOG"
    ! grep -q "release create" "$GH_LOG"   # release exists, so no create call
}

@test "run_verify attach: go uploads the dist archives, their bundles, and checksums.txt (wrangle owns the publish)" {
    _require_zip
    _install_gh_shim
    _stage_release_assets
    : > "$DIST_DIR/checksums.txt"
    export BUILD_TYPE="go"
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    grep -qx "release upload v1.2.3 $BUNDLE_OUT/a.tgz.intoto.jsonl --clobber" "$GH_LOG"
    grep -qx "release upload v1.2.3 $DIST_DIR/a.tgz --clobber" "$GH_LOG"
    grep -qx "release upload v1.2.3 $DIST_DIR/b.whl --clobber" "$GH_LOG"
    # checksums.txt has no bundle of its own but is part of the attested set.
    grep -qx "release upload v1.2.3 $DIST_DIR/checksums.txt --clobber" "$GH_LOG"
    grep -q "release upload v1.2.3 .*python-metadata.zip --clobber" "$GH_LOG"
}

@test "run_verify attach: go fails closed when checksums.txt is missing" {
    _require_zip
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="go"        # no checksums.txt staged
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"checksums.txt"* ]]
}

@test "run_verify attach: a bundle whose dist is missing fails closed (no orphan bundle)" {
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="python"
    rm -f "$DIST_DIR/a.tgz"          # orphan: bundle present, dist gone
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found"* ]]
}

@test "run_verify attach: the metadata zip carries the bundles and the sbom" {
    _require_zip
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="python"
    export GH_VIEW_SEQ="0"
    # The gh shim copies the uploaded metadata zip aside so its contents can be
    # asserted without re-zipping or needing unzip (`zip -sf` lists in-place).
    export GH_KEEP_ZIP="$TEST_DIR/kept.zip"
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    run zip -sf "$GH_KEEP_ZIP"
    [[ "$output" == *"a.tgz.intoto.jsonl"* ]]
    [[ "$output" == *"sbom.spdx.json"* ]]
}

# The metadata zip is sourced from METADATA_ROOT, not BUNDLE_OUT: a sbom that
# lives only under METADATA_ROOT must still land in the zip.
@test "run_verify attach: the metadata zip is taken from METADATA_ROOT, not BUNDLE_OUT" {
    _require_zip
    _install_gh_shim
    _stage_release_assets
    export METADATA_ROOT="$TEST_DIR/meta"
    mkdir -p "$METADATA_ROOT"
    : > "$METADATA_ROOT/sbom.spdx.json"
    mkdir -p "$METADATA_ROOT/scan/osv"
    : > "$METADATA_ROOT/scan/osv/output.sarif"
    rm -f "$BUNDLE_OUT/sbom.spdx.json"
    export BUILD_TYPE="python"
    export GH_VIEW_SEQ="0"
    export GH_KEEP_ZIP="$TEST_DIR/kept.zip"
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    run zip -sf "$GH_KEEP_ZIP"
    [[ "$output" == *"sbom.spdx.json"* ]]
    [[ "$output" == *"scan/osv/output.sarif"* ]]
}

# Two subjects resolving to the same bundle basename would clobber/cross-wire on
# upload (assets attach by basename) — fail closed before any upload.
@test "run_verify attach: duplicate bundle basename fails closed" {
    _install_gh_shim
    _stage_release_assets
    mkdir -p "$BUNDLE_OUT/sub"
    : > "$BUNDLE_OUT/sub/a.tgz.intoto.jsonl"   # same basename as $BUNDLE_OUT/a.tgz.intoto.jsonl
    export BUILD_TYPE="python"
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"duplicate release-asset basename"* ]]
}

@test "run_verify attach: missing release is created, then assets upload" {
    _require_zip
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="python"
    export GH_VIEW_SEQ="1"            # view fails (no release)
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    grep -qx "release create v1.2.3 --draft --generate-notes --title v1.2.3" "$GH_LOG"
    grep -qx "release upload v1.2.3 $BUNDLE_OUT/a.tgz.intoto.jsonl --clobber" "$GH_LOG"
}

@test "run_verify attach: a failed release create fails closed, uploads nothing" {
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="python"
    export GH_VIEW_SEQ="1 1"          # release absent before and after the failed create
    export GH_CREATE_CODE="1"        # create fails
    run "$SCRIPT" attach
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"failed to create GitHub release"* ]]
    if grep -q "release upload" "$GH_LOG"; then return 1; fi
}

@test "run_verify attach: a create that loses the concurrent race still uploads" {
    _require_zip
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="python"
    export GH_VIEW_SEQ="1 0"          # absent, then a peer job's release appears
    export GH_CREATE_CODE="1"        # our create loses the race
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    grep -qx "release create v1.2.3 --draft --generate-notes --title v1.2.3" "$GH_LOG"
    grep -qx "release upload v1.2.3 $BUNDLE_OUT/a.tgz.intoto.jsonl --clobber" "$GH_LOG"
}

# The verify job has no checkout, so gh resolves the base repo from GH_REPO
# alone; without it `release view` can't find the release and the attach
# silently no-ops even when a release exists. Drive a gh shim whose `release
# view` succeeds ONLY when GH_REPO names the expected repo, and prove the attach
# proceeds to upload (rather than hitting the no-release branch).
@test "run_verify attach: resolves the release via GH_REPO and proceeds to upload" {
    _require_zip
    cat > "$TEST_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "release view") [[ "${GH_REPO:-}" == "o/r" ]] && exit 0 || exit 1 ;;
esac
exit 0
SHIM
    chmod +x "$TEST_DIR/gh"
    export PATH="$TEST_DIR:$PATH"
    export GH_LOG="$TEST_DIR/gh.log"; : > "$GH_LOG"
    export GITHUB_REF_NAME="v1.2.3"
    export GH_REPO="o/r"
    _stage_release_assets
    export BUILD_TYPE="python"
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"workflow artifact only"* ]]
    grep -qx "release upload v1.2.3 $BUNDLE_OUT/a.tgz.intoto.jsonl --clobber" "$GH_LOG"
}

# --- draft -> attach -> publish ordering (#407, immutable releases) ---
#
# ensure_release creates a DRAFT so assets attach before publish; the flow flips
# the draft to published as its FINAL act. Immutable releases freeze at publish,
# so no asset/body edit may follow the flip.

@test "run_verify attach: creates the release as a draft, then publishes it" {
    _require_zip
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="python"
    export GH_VIEW_SEQ="1"            # no release yet -> create as draft
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    grep -qx "release create v1.2.3 --draft --generate-notes --title v1.2.3" "$GH_LOG"
    grep -qx "release edit v1.2.3 --draft=false" "$GH_LOG"
}

@test "run_verify attach: the publish flip is the LAST gh mutation (no upload/edit after it)" {
    # LOAD-BEARING for immutable releases: every asset + body edit must land while
    # the release is still a draft. A stray upload/edit after --draft=false hits a
    # frozen release.
    _require_zip
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="go"
    : > "$DIST_DIR/checksums.txt"
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    # The flip must be the final release-mutating call in the log.
    local last
    last="$(grep -nE 'release (upload|create|edit)' "$GH_LOG" | tail -n1)"
    [[ "$last" == *"release edit v1.2.3 --draft=false"* ]]
}

@test "run_verify attach: a failed metadata-zip upload fails closed before the publish flip" {
    # The metadata zip is the last asset; its upload failure MUST abort the attach
    # before wrangle_publish_release flips the draft — else an incomplete release
    # freezes as published on immutable. Regression guard: the helper runs on the
    # left of `||`, so set -e is disabled in its body and a swallowed failure
    # would let the flip proceed.
    _require_zip
    _install_gh_shim
    _stage_release_assets
    export BUILD_TYPE="python"
    export GH_VIEW_SEQ="0"
    export GH_ZIP_UPLOAD_CODE=1      # only the metadata-zip upload fails
    run "$SCRIPT" attach
    [[ "$status" -ne 0 ]]
    # The draft must NOT have been published.
    if grep -q "release edit v1.2.3 --draft=false" "$GH_LOG"; then return 1; fi
}

@test "run_verify: ensure_release creates a draft when the release is absent" {
    _install_gh_shim
    export GH_VIEW_SEQ="1 1"          # absent, and the post-create re-check is not reached
    run wrangle_ensure_release v1.2.3
    [[ "$status" -eq 0 ]]
    grep -qx "release create v1.2.3 --draft --generate-notes --title v1.2.3" "$GH_LOG"
}

@test "run_verify: ensure_release is race-safe — a lost create succeeds if the release now exists" {
    # Sibling build-type publishes race to create the same release; the loser's
    # create 422s, but the release exists by then, so publish must proceed.
    _install_gh_shim
    export GH_VIEW_SEQ="1 0"          # absent, then present (another job won the create)
    export GH_CREATE_CODE=1           # our create loses the race
    run wrangle_ensure_release v1.2.3
    [[ "$status" -eq 0 ]]
}

@test "run_verify: ensure_release fails closed when create fails and the release stays absent" {
    _install_gh_shim
    export GH_VIEW_SEQ="1 1"          # absent, still absent
    export GH_CREATE_CODE=1
    run wrangle_ensure_release v1.2.3
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"failed to create"* ]]
}

@test "run_verify: publish_release flips the draft to published" {
    _install_gh_shim
    run wrangle_publish_release v1.2.3
    [[ "$status" -eq 0 ]]
    grep -qx "release edit v1.2.3 --draft=false" "$GH_LOG"
}

@test "run_verify: publish_release tolerates an already-published release (sibling won the flip)" {
    # A concurrent sibling build-type publish already flipped it: gh edit may
    # fail, but the release is published, so this must still succeed.
    _install_gh_shim
    export GH_EDIT_CODE=1             # our flip errors
    export GH_ISDRAFT=false           # ...but the release is already published
    run wrangle_publish_release v1.2.3
    [[ "$status" -eq 0 ]]
}

@test "run_verify: publish_release fails closed when the flip fails and the release is still a draft" {
    _install_gh_shim
    export GH_EDIT_CODE=1
    export GH_ISDRAFT=true
    run wrangle_publish_release v1.2.3
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"failed to publish"* ]]
}

# --- attach-unattested (wrangle_attach_unattested) ---
#
# The disabled-attestation publish: no bundles or VSAs, so every dist file (go:
# archives + checksums.txt) and the metadata zip are uploaded, the release body
# is marked unattested (before the publish flip), and the draft is published.

# Stage a dist dir (no bundles) + the metadata dir, plus the env attach-unattested
# reads. The metadata zip is sourced from METADATA_ROOT.
_stage_unattested_assets() {
    mkdir -p "$TEST_DIR/dist" "$TEST_DIR/meta"
    : > "$TEST_DIR/dist/app-linux-amd64.tar.gz"
    printf 'deadbeef  app-linux-amd64.tar.gz\n' > "$TEST_DIR/dist/checksums.txt"
    : > "$TEST_DIR/meta/sbom.spdx.json"
    export DIST_DIR="$TEST_DIR/dist"
    export METADATA_ROOT="$TEST_DIR/meta"
    export METADATA_ZIP_NAME="go-metadata.zip"
    export GH_BODY="$TEST_DIR/body"; : > "$GH_BODY"
    export GH_NOTES="$TEST_DIR/notes"; : > "$GH_NOTES"
}

@test "run_verify attach-unattested: uploads every dist file + checksums.txt and the metadata zip, no bundles" {
    _require_zip
    _install_gh_shim
    _stage_unattested_assets
    export GH_VIEW_SEQ="0"            # release exists
    run "$SCRIPT" attach-unattested
    [[ "$status" -eq 0 ]]
    grep -qx "release upload v1.2.3 $DIST_DIR/app-linux-amd64.tar.gz --clobber" "$GH_LOG"
    grep -qx "release upload v1.2.3 $DIST_DIR/checksums.txt --clobber" "$GH_LOG"
    grep -q "release upload v1.2.3 .*go-metadata.zip --clobber" "$GH_LOG"
    # No bundle (.intoto.jsonl) is uploaded in unattested mode.
    if grep -q "intoto.jsonl" "$GH_LOG"; then return 1; fi
    # The draft is published as the final step.
    grep -qx "release edit v1.2.3 --draft=false" "$GH_LOG"
}

@test "run_verify attach-unattested: the marker edit precedes the publish flip (immutable-safe)" {
    # The body marker is a gh release edit; it MUST land before --draft=false or it
    # re-violates immutability on the adopter's release.
    _require_zip
    _install_gh_shim
    _stage_unattested_assets
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach-unattested
    [[ "$status" -eq 0 ]]
    local marker_line flip_line
    marker_line="$(grep -n 'release edit v1.2.3 --notes' "$GH_LOG" | head -n1 | cut -d: -f1)"
    flip_line="$(grep -n 'release edit v1.2.3 --draft=false' "$GH_LOG" | head -n1 | cut -d: -f1)"
    [[ -n "$marker_line" && -n "$flip_line" ]]
    [[ "$marker_line" -lt "$flip_line" ]]
    # And the flip is the last mutation.
    local last
    last="$(grep -nE 'release (upload|create|edit)' "$GH_LOG" | tail -n1)"
    [[ "$last" == *"release edit v1.2.3 --draft=false"* ]]
}

@test "run_verify attach-unattested: a checksums manifest scopes the upload, excluding build-tool bookkeeping" {
    # A build tool (e.g. goreleaser) writes config.yaml / artifacts.json /
    # metadata.json / CHANGELOG.md into dist/; a flat glob would wrongly publish
    # them. With a checksums manifest present, publish only its entries.
    _require_zip
    _install_gh_shim
    _stage_unattested_assets
    : > "$DIST_DIR/config.yaml"
    : > "$DIST_DIR/artifacts.json"
    : > "$DIST_DIR/metadata.json"
    : > "$DIST_DIR/CHANGELOG.md"
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach-unattested
    [[ "$status" -eq 0 ]]
    grep -qx "release upload v1.2.3 $DIST_DIR/app-linux-amd64.tar.gz --clobber" "$GH_LOG"
    grep -qx "release upload v1.2.3 $DIST_DIR/checksums.txt --clobber" "$GH_LOG"
    local bk
    for bk in config.yaml artifacts.json metadata.json CHANGELOG.md; do
        if grep -qF "$bk" "$GH_LOG"; then
            printf 'leaked bookkeeping: %s\n' "$bk" >&2
            return 1
        fi
    done
}

@test "run_verify attach-unattested: with no checksums manifest, uploads every flat dist file (npm/python)" {
    # Build types without a checksums manifest (their dist holds only real
    # artifacts) publish the flat dist — no manifest scoping, no build-type branch.
    _require_zip
    _install_gh_shim
    mkdir -p "$TEST_DIR/dist" "$TEST_DIR/meta"
    : > "$TEST_DIR/dist/pkg-1.0.0-py3-none-any.whl"
    : > "$TEST_DIR/dist/pkg-1.0.0.tar.gz"
    : > "$TEST_DIR/meta/sbom.spdx.json"
    export DIST_DIR="$TEST_DIR/dist"
    export METADATA_ROOT="$TEST_DIR/meta"
    export METADATA_ZIP_NAME="python-metadata.zip"
    export GH_BODY="$TEST_DIR/body"; : > "$GH_BODY"
    export GH_NOTES="$TEST_DIR/notes"; : > "$GH_NOTES"
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach-unattested
    [[ "$status" -eq 0 ]]
    grep -qx "release upload v1.2.3 $DIST_DIR/pkg-1.0.0-py3-none-any.whl --clobber" "$GH_LOG"
    grep -qx "release upload v1.2.3 $DIST_DIR/pkg-1.0.0.tar.gz --clobber" "$GH_LOG"
    grep -q "release upload v1.2.3 .*python-metadata.zip --clobber" "$GH_LOG"
}

@test "run_verify attach-unattested: marks the release body as unattested" {
    _require_zip
    _install_gh_shim
    _stage_unattested_assets
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach-unattested
    [[ "$status" -eq 0 ]]
    grep -q "release edit v1.2.3 --notes" "$GH_LOG"
    grep -q "issues/600" "$GH_NOTES"
}

@test "run_verify attach-unattested: preserves a pre-existing release body and appends the marker" {
    # Generated/adopter notes must survive: the marker is appended, not a
    # wholesale --notes replacement that would destroy the existing body.
    _require_zip
    _install_gh_shim
    _stage_unattested_assets
    printf 'Adopter changelog line.\n' > "$GH_BODY"
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach-unattested
    [[ "$status" -eq 0 ]]
    grep -q "Adopter changelog line." "$GH_NOTES"
    grep -q "issues/600" "$GH_NOTES"
}

@test "run_verify attach-unattested: is idempotent — a re-run does not double-append the marker" {
    # The marker's unique key suppresses a second append when it is already
    # present (a re-run must not stack markers).
    _install_gh_shim
    _stage_unattested_assets
    # Body already carries the marker key.
    printf 'Notes.\n\n> [!WARNING]\n> Unattested build (attest-and-verify: disabled) — no SLSA provenance or VSA.\n' > "$GH_BODY"
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach-unattested
    [[ "$status" -eq 0 ]]
    # mark_release_unattested returns early without editing the notes.
    if grep -q "release edit v1.2.3 --notes" "$GH_LOG"; then return 1; fi
}

@test "run_verify attach-unattested: appends the marker even when notes already contain an unrelated alert" {
    # The idempotency key must be unique to the unattested marker, not a generic
    # alert line: an adopter's own `> [!WARNING]` block must not suppress it.
    _install_gh_shim
    _stage_unattested_assets
    {
        printf '> [!WARNING]\n'
        printf '> Breaking change in this release.\n'
    } > "$GH_BODY"
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach-unattested
    [[ "$status" -eq 0 ]]
    grep -q "release edit v1.2.3 --notes" "$GH_LOG"
    grep -q "issues/600" "$GH_NOTES"
}

@test "run_verify attach-unattested: a failed metadata-zip upload fails closed before the publish flip" {
    _require_zip
    _install_gh_shim
    _stage_unattested_assets
    export GH_VIEW_SEQ="0"
    export GH_ZIP_UPLOAD_CODE=1      # only the metadata-zip upload fails
    run "$SCRIPT" attach-unattested
    [[ "$status" -ne 0 ]]
    if grep -q "release edit v1.2.3 --draft=false" "$GH_LOG"; then return 1; fi
}

@test "run_verify attach-unattested: fails closed when dist has no artifacts" {
    _install_gh_shim
    mkdir -p "$TEST_DIR/dist" "$TEST_DIR/meta"   # empty dist, no checksums
    : > "$TEST_DIR/meta/sbom.spdx.json"
    export DIST_DIR="$TEST_DIR/dist"
    export METADATA_ROOT="$TEST_DIR/meta"
    export METADATA_ZIP_NAME="python-metadata.zip"
    export GH_BODY="$TEST_DIR/body"; : > "$GH_BODY"
    export GH_NOTES="$TEST_DIR/notes"; : > "$GH_NOTES"
    export GH_VIEW_SEQ="0"
    run "$SCRIPT" attach-unattested
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no dist files to publish"* ]]
}

# --- wrangle_retry_once -----------------------------------------------------

# Shim whose first invocation fails after partial output and whose second
# succeeds — the transient-Sigstore shape the retry exists for.
make_flaky() {
    local mode="$1" shim="$TEST_DIR/flaky"
    cat > "$shim" <<SHIM
#!/usr/bin/env bash
calls="\$0.calls"
printf 'x\n' >> "\$calls"
n="\$(wc -l < "\$calls")"
case "$mode" in
    pass)       printf 'good\n'; exit 0 ;;
    fail-once)  if [[ "\$n" -eq 1 ]]; then printf 'partial\n'; exit 1; fi
                printf 'good\n'; exit 0 ;;
    fail-always) printf 'broken\n'; exit 1 ;;
esac
SHIM
    chmod +x "$shim"
    printf '%s\n' "$shim"
}

@test "retry: passing command runs exactly once" {
    shim="$(make_flaky pass)"
    run wrangle_retry_once "$TEST_DIR/out" "$shim"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$shim.calls")" -eq 1 ]]
    [[ "$(cat "$TEST_DIR/out")" == "good" ]]
}

@test "retry: transient failure retries once and the capture holds only the retry's output" {
    shim="$(make_flaky fail-once)"
    run wrangle_retry_once "$TEST_DIR/out" "$shim"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$shim.calls")" -eq 2 ]]
    [[ "$output" == *"retrying once"* ]]
    # The notice carries the first attempt's real exit code, not a stale $?.
    [[ "$output" == *"(exit 1)"* ]]
    # Truncated per attempt: no 'partial' residue from the failed first try.
    [[ "$(cat "$TEST_DIR/out")" == "good" ]]
}

@test "retry: deterministic failure still fails closed after the second attempt" {
    shim="$(make_flaky fail-always)"
    run wrangle_retry_once "$TEST_DIR/out" "$shim"
    [[ "$status" -ne 0 ]]
    [[ "$(wc -l < "$shim.calls")" -eq 2 ]]
}

# A digest-pinned curated toolbox image (wrangle namespace) for the gate tests.
_toolbox_image="ghcr.io/tomhennen/wrangle/attest-toolbox@sha256:0000000000000000000000000000000000000000000000000000000000000000"

# Write a stub catalog with the attest-toolbox grant ($1 = image; default the
# pinned curated image; $2 = token grant, e.g. sigstore, when set) and export
# WRANGLE_CATALOG at it.
_stub_toolbox_catalog() {
    local image="${1:-$_toolbox_image}" token="${2:-}" token_field=""
    [[ -n "$token" ]] && token_field=",\"token\":\"$token\""
    cat > "$TEST_DIR/catalog.json" <<JSON
{"tools":{"attest-toolbox":{"kind":"attest","image":"$image","network":"egress"$token_field}}}
JSON
    export WRANGLE_CATALOG="$TEST_DIR/catalog.json"
}

# Shim curl so the sigstore-token mint returns a fixed JWT value without network.
_stub_mint_curl() {
    cat > "$TEST_DIR/curl" <<'EOF'
#!/bin/bash
printf '{"value":"MINTED-SIGSTORE-JWT"}\n'
EOF
    chmod +x "$TEST_DIR/curl"
    export ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token"
    export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-bearer-secret"
}

# Install a docker shim that records its argv, and a gh shim whose attestation
# verdict is PASSED (the real --format json shape) or, with GH_FAIL=1, FAILED.
_install_toolbox_shims() {
    cat > "$TEST_DIR/docker" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$TEST_DIR/docker.args"
# bnd statement (VSA signing) writes the signed statement to stdout; emit a
# placeholder so the caller's non-empty-output guard (empty = fail closed) is met.
case "\$*" in *"bnd statement"*) printf '{"signed":"vsa"}\n' ;; esac
EOF
    chmod +x "$TEST_DIR/docker"
    cat > "$TEST_DIR/gh" <<EOF
#!/bin/bash
verdict=PASSED
[[ -n "\${GH_FAIL:-}" ]] && verdict=FAILED
cat <<JSON
[{"verificationResult":{"statement":{"predicate":{"verificationResult":"\$verdict","resourceUri":"$_toolbox_image","verifiedLevels":["SLSA_BUILD_LEVEL_3"]}}}}]
JSON
EOF
    chmod +x "$TEST_DIR/gh"
}

@test "wrangle_engine_verify: one VSA-gated toolbox run with a minted, name-threaded token" {
    _install_toolbox_shims
    _stub_toolbox_catalog "$_toolbox_image" sigstore
    _stub_mint_curl
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"; : > "$GITHUB_STEP_SUMMARY"
    PATH="$TEST_DIR:$PATH" run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [ "$status" -eq 0 ]
    grep -q "toolbox-image VSA verified PASSED" <<< "$output"
    grep -q -- "--network bridge" "$TEST_DIR/docker.args"
    grep -q -- "$_toolbox_image wrangle-attest verify" "$TEST_DIR/docker.args"
    # The engine signs the VSA, so the sigstore token rides this run — threaded
    # by NAME only, its value never on argv; the engine strips it from ampel's
    # child env (asserted in go test ./wrangle-attest/).
    grep -q -- "-e SIGSTORE_ID_TOKEN" "$TEST_DIR/docker.args"
    ! grep -q "MINTED-SIGSTORE-JWT" "$TEST_DIR/docker.args"
    # The mint-anything request vars NEVER enter the container.
    ! grep -q "ACTIONS_ID_TOKEN_REQUEST" "$TEST_DIR/docker.args"
    # No registry login token without an oci: collector.
    ! grep -q -- "-e GITHUB_TOKEN" "$TEST_DIR/docker.args"
}

@test "wrangle_engine_verify: a non-PASSED toolbox VSA fails closed (no docker)" {
    _install_toolbox_shims
    _stub_toolbox_catalog "$_toolbox_image" sigstore
    _stub_mint_curl
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"; : > "$GITHUB_STEP_SUMMARY"
    PATH="$TEST_DIR:$PATH" GH_FAIL=1 run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [ "$status" -ne 0 ]
    grep -q "verification failed" <<< "$output"
    [ ! -f "$TEST_DIR/docker.args" ]
}

@test "wrangle_engine_verify: a missing catalog grant fails closed before any dispatch (no docker)" {
    _install_toolbox_shims
    echo '{"tools":{}}' > "$TEST_DIR/catalog.json"
    export WRANGLE_CATALOG="$TEST_DIR/catalog.json"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"; : > "$GITHUB_STEP_SUMMARY"
    PATH="$TEST_DIR:$PATH" run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [ "$status" -ne 0 ]
    # The signing run mints first, so the empty catalog trips the token gate.
    grep -q "capability required to sign" <<< "$output"
    [ ! -f "$TEST_DIR/docker.args" ]
}

@test "wrangle_engine_verify: a non-digest-pinned catalog image is rejected (no docker)" {
    _install_toolbox_shims
    _stub_toolbox_catalog "ghcr.io/tomhennen/wrangle/attest-toolbox:latest" sigstore
    _stub_mint_curl
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"; : > "$GITHUB_STEP_SUMMARY"
    PATH="$TEST_DIR:$PATH" run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [ "$status" -ne 0 ]
    grep -q "digest-pinned" <<< "$output"
    [ ! -f "$TEST_DIR/docker.args" ]
}

@test "wrangle_engine_verify: an OCI collector adds the job's registry auth to the run" {
    _install_toolbox_shims
    _stub_toolbox_catalog "$_toolbox_image" sigstore
    _stub_mint_curl
    export GITHUB_TOKEN="registry-token" HOME="$TEST_DIR"
    mkdir -p "$TEST_DIR/.docker"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"; : > "$GITHUB_STEP_SUMMARY"
    PATH="$TEST_DIR:$PATH" COLLECTOR="oci:ghcr.io/x@sha256:abc" \
        run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [ "$status" -eq 0 ]
    grep -q -- "$_toolbox_image wrangle-attest verify" "$TEST_DIR/docker.args"
    # Registry read needs the job's ghcr login and token by name, not value.
    grep -q -- "-e GITHUB_TOKEN" "$TEST_DIR/docker.args"
    ! grep -q "registry-token" "$TEST_DIR/docker.args"
    grep -q -- "-e DOCKER_CONFIG=/wrangle/docker-config" "$TEST_DIR/docker.args"
}

@test "wrangle_engine_verify: a failed token mint fails closed (no docker)" {
    _install_toolbox_shims
    _stub_toolbox_catalog "$_toolbox_image" sigstore
    # Grant present but the ambient OIDC request vars absent -> mint fails.
    unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN SIGSTORE_ID_TOKEN
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"; : > "$GITHUB_STEP_SUMMARY"
    PATH="$TEST_DIR:$PATH" run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [ "$status" -ne 0 ]
    grep -q "lacks id-token: write" <<< "$output"
    [ ! -f "$TEST_DIR/docker.args" ]
}

@test "wrangle_engine_verify: WRANGLE_VERIFY_TOOL_IMAGES=0 skips the VSA gate for a Sigstore outage" {
    # The sole path that dispatches without verifying — gh must never be consulted.
    cat > "$TEST_DIR/gh" <<EOF
#!/bin/bash
touch "$TEST_DIR/gh.called"
EOF
    chmod +x "$TEST_DIR/gh"
    cat > "$TEST_DIR/docker" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$TEST_DIR/docker.args"
EOF
    chmod +x "$TEST_DIR/docker"
    _stub_toolbox_catalog "$_toolbox_image" sigstore
    _stub_mint_curl
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"; : > "$GITHUB_STEP_SUMMARY"
    PATH="$TEST_DIR:$PATH" WRANGLE_VERIFY_TOOL_IMAGES=0 run wrangle_engine_verify "sha256:abc" "$VSA" "$TEST_DIR/b.jsonl"
    [ "$status" -eq 0 ]
    grep -q "verification disabled by configuration" <<< "$output"
    [ ! -f "$TEST_DIR/gh.called" ]
    grep -q -- "$_toolbox_image wrangle-attest verify" "$TEST_DIR/docker.args"
}

@test "retry: the engine verify run is not wrapped in the in-shell retry" {
    # The engine retries the ampel exec itself and the signer retries Sigstore
    # I/O; an in-shell re-run after a torn bundle append could double-append.
    # The push paths (lib/sign_metadata.sh) keep their wrangle_retry_once.
    ! grep -q 'wrangle_retry_once' "$SCRIPT"
}
