#!/usr/bin/env bats

# Tests for actions/verify/run_verify.sh
#
# The arg-builder functions are validated against the shape the real
# ampel/bnd/cosign CLIs accept. Full keyless bnd signing needs OIDC and cannot
# run offline, so the sign path is checked at the argument-vector level only;
# the emit and run paths are exercised end-to-end with tiny ampel/bnd/cosign
# stubs on PATH to confirm the per-subject emit -> sign -> append plumbing.
#
# skip_or_fail (fail-not-skip under CI) lives in a shared bats helper. The real
# ampel/bnd/cosign are installed only in the `integration (real binaries)` job,
# so a skip there means coverage silently degraded; the unit suite has no real
# binaries and skips these by design.
load "../../test/lib/bats_helpers"

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/run_verify.sh"
    TEST_DIR="$(mktemp -d)"

    # Discover the real ampel/bnd wherever they're installed (PATH or the
    # action's WRANGLE_BIN_DIR), so the integration assertions actually run in
    # any job that built the tools and skip only when they're genuinely absent.
    AMPEL_BIN="$(command -v ampel || echo "${WRANGLE_BIN_DIR:-/nonexistent}/ampel")"
    BND_BIN="$(command -v bnd || echo "${WRANGLE_BIN_DIR:-/nonexistent}/bnd")"
    COSIGN_BIN="$(command -v cosign || echo "${WRANGLE_BIN_DIR:-/nonexistent}/cosign")"
    ATTEST_BIN="$(command -v wrangle-attest || echo "${WRANGLE_BIN_DIR:-/nonexistent}/wrangle-attest")"

    export SUBJECTS=$'dist/app-1.2.3.tgz'
    export POLICY="policies/release.json"
    export COLLECTOR="jsonl:./atts"
    export FAIL="true"
    export CONTEXT=""
    export ATTESTATION=""
    export OCI_TARGET=""
    export BUNDLE_IN="$TEST_DIR/provenance.jsonl"
    # bundle-out is the directory the per-artifact bundles are written into.
    export BUNDLE_OUT="$TEST_DIR/bundles"
    export GITHUB_REPOSITORY="o/r"
    export RUNNER_TEMP="$TEST_DIR"
    # The unsigned-VSA path the arg-vector tests reference.
    VSA="$TEST_DIR/vsa.intoto.jsonl"
    # No real Sigstore here, so the inter-attempt backoff is pure dead time.
    export WRANGLE_RETRY_DELAY=0

    # shellcheck source=run_verify.sh
    source "$SCRIPT"
    # wrangle_verify_emit_vsa uses wrangle_sanitize_output, which run() sources
    # at runtime; load it here so the direct-call emit tests have it too.
    # shellcheck source=../../lib/sanitize.sh
    source "$(cd "$(dirname "$BATS_TEST_FILENAME")/../../lib" && pwd)/sanitize.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "run_verify: exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "run_verify: a policy locator passes through unresolved" {
    export POLICY="git+https://github.com/o/r@abc123#policies/x.hjson"
    mapfile -t args < <(wrangle_ampel_verify_args "sha256:abc" "$VSA")
    printf '%s\n' "${args[@]}" | grep -qx -- "--policy=git+https://github.com/o/r@abc123#policies/x.hjson"
}

@test "run_verify: an absolute policy path passes through unresolved" {
    # The absolute-path arm fails SILENTLY if dropped (an absolute path would be
    # double-prefixed to $REPO_ROOT/abs/… and ampel would read the wrong file),
    # so it gets its own guard distinct from the locator case.
    export POLICY="/etc/wrangle/policy.hjson"
    mapfile -t args < <(wrangle_ampel_verify_args "sha256:abc" "$VSA")
    printf '%s\n' "${args[@]}" | grep -qx -- "--policy=/etc/wrangle/policy.hjson"
}

# --- subject arg (single-sha256 subject) ---

@test "run_verify: subject_arg hashes a file subject to a single sha256 --subject-hash" {
    # The store rejects a multi-digest subject; passing the file as a precomputed
    # sha256 hash keeps the VSA subject single-digest (ampel's file hasher would
    # otherwise add sha512).
    printf 'CONTENT\n' > "$TEST_DIR/blob"
    local want; want="$(sha256sum "$TEST_DIR/blob" | cut -d' ' -f1)"
    run wrangle_subject_arg "$TEST_DIR/blob"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "--subject-hash=sha256:$want" ]]
}

@test "run_verify: subject_arg passes a digest subject through as --subject" {
    # A container subject is already a digest; ampel synthesizes a single-digest
    # descriptor from it, so it needs no re-hashing.
    run wrangle_subject_arg "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "--subject=sha256:0000000000000000000000000000000000000000000000000000000000000000" ]]
}

@test "run_verify: subject_arg fails closed on an unreadable file subject" {
    run wrangle_subject_arg "$TEST_DIR/does-not-exist.tgz"
    [[ "$status" -ne 0 ]]
}

# --- wrangle-attest arg vector ---

@test "run_verify: attest args carry the metadata-root, subject arg, sign, and out" {
    export METADATA_ROOT="$TEST_DIR/meta"
    mapfile -t args < <(wrangle_attest_args "--subject=sha256:abc" "$TEST_DIR/out.jsonl")
    printf '%s\n' "${args[@]}" | grep -qx -- "--metadata-root=$TEST_DIR/meta"
    printf '%s\n' "${args[@]}" | grep -qx -- "--subject=sha256:abc"
    printf '%s\n' "${args[@]}" | grep -qx -- "--sign"
    printf '%s\n' "${args[@]}" | grep -qx -- "--out=$TEST_DIR/out.jsonl"
}

@test "run_verify: attest args pass an --artifact subject arg through verbatim" {
    export METADATA_ROOT="$TEST_DIR/meta"
    mapfile -t args < <(wrangle_attest_args "--artifact=$TEST_DIR/dist/a.tgz" "$TEST_DIR/out.jsonl")
    printf '%s\n' "${args[@]}" | grep -qx -- "--artifact=$TEST_DIR/dist/a.tgz"
}

@test "run_verify: attest arg vector is accepted by the real wrangle-attest parser" {
    # The real engine rejects an unknown flag; a run that gets past flag parsing
    # (failing later on the bogus subject/root) proves every flag name matches.
    if [[ ! -x "$ATTEST_BIN" ]]; then skip_or_fail "real wrangle-attest not available"; fi
    export METADATA_ROOT="$TEST_DIR/meta"
    mapfile -t args < <(wrangle_attest_args "--subject=sha256:abc" "$TEST_DIR/out.jsonl")
    run "$ATTEST_BIN" "${args[@]}"
    [[ "$status" -ne 0 ]]
    [[ "$output" != *"flag provided but not defined"* ]]
}

# --- ampel arg vector ---

@test "run_verify: ampel args carry the core verify flags for the given subject" {
    mapfile -t args < <(wrangle_ampel_verify_args "sha256:abc123" "$VSA")
    [[ "${args[0]}" == "verify" ]]
    printf '%s\n' "${args[@]}" | grep -qx -- "--subject=sha256:abc123"
    printf '%s\n' "${args[@]}" | grep -qx -- "--collector=jsonl:./atts"
    # A relative policy path is resolved to an absolute path under the action's checkout.
    printf '%s\n' "${args[@]}" | grep -qE -- "^--policy=/.*/policies/release\.json$"
    printf '%s\n' "${args[@]}" | grep -qx -- "--exit-code=true"
    printf '%s\n' "${args[@]}" | grep -qx -- "--attest-results"
    printf '%s\n' "${args[@]}" | grep -qx -- "--attest-format=vsa"
    printf '%s\n' "${args[@]}" | grep -qx -- "--results-path=$VSA"
    printf '%s\n' "${args[@]}" | grep -qx -- "--format=html"
}

@test "run_verify: ampel args omit context and attestation when empty" {
    mapfile -t args < <(wrangle_ampel_verify_args "sha256:abc" "$VSA")
    if printf '%s\n' "${args[@]}" | grep -qx -- "--context"; then return 1; fi
    if printf '%s\n' "${args[@]}" | grep -qx -- "--attestation"; then return 1; fi
}

@test "run_verify: ampel args include context and attestation when set" {
    export CONTEXT="buildPoint:git+https://github.com/o/r"
    export ATTESTATION="att.intoto.json"
    mapfile -t args < <(wrangle_ampel_verify_args "sha256:abc" "$VSA")
    # --context is followed by its value as a separate argument
    found_ctx=0
    for i in "${!args[@]}"; do
        if [[ "${args[$i]}" == "--context" && "${args[$((i+1))]}" == "$CONTEXT" ]]; then
            found_ctx=1
        fi
        if [[ "${args[$i]}" == "--attestation" && "${args[$((i+1))]}" == "$ATTESTATION" ]]; then
            found_att=1
        fi
    done
    [[ "$found_ctx" -eq 1 ]]
    [[ "${found_att:-0}" -eq 1 ]]
}

@test "run_verify: ampel arg vector is accepted by the real ampel parser" {
    # The real ampel rejects an unknown flag with a non-"subject" error; a bad
    # subject means every flag in our vector parsed. Confirms the flag names
    # match the installed CLI without needing real attestations.
    if [[ ! -x "$AMPEL_BIN" ]]; then skip_or_fail "real ampel not available"; fi
    mapfile -t args < <(wrangle_ampel_verify_args "sha256:abc" "$VSA")
    run "$AMPEL_BIN" "${args[@]}"
    [[ "$status" -ne 0 ]]
    [[ "$output" != *"unknown flag"* ]]
    [[ "$output" != *"unknown shorthand"* ]]
}

# --- bnd arg vector ---

@test "run_verify: bnd sign args are 'statement <unsigned-path>'" {
    mapfile -t args < <(wrangle_bnd_sign_args "$VSA.unsigned")
    [[ "${args[0]}" == "statement" ]]
    [[ "${args[1]}" == "$VSA.unsigned" ]]
    [[ "${#args[@]}" -eq 2 ]]
}

@test "run_verify: bnd sign args name a real bnd subcommand" {
    if [[ ! -x "$BND_BIN" ]]; then skip_or_fail "real bnd not available"; fi
    # `bnd statement --help` proves the subcommand exists without triggering
    # the keyless signing flow (which blocks on OIDC offline).
    run "$BND_BIN" statement --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"in-toto attestation"* ]]
}

# --- cosign arg vectors (OCI bundle round-trip) ---

@test "run_verify: cosign download args fetch the image's attestation referrers" {
    local target="ghcr.io/o/r/img@sha256:abc"
    mapfile -t args < <(wrangle_cosign_download_args "$target")
    [[ "${args[0]}" == "download" ]]
    [[ "${args[1]}" == "attestation" ]]
    [[ "${args[-1]}" == "$target" ]]
}

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

@test "run_verify: cosign download arg vector names a real cosign subcommand" {
    if [[ ! -x "$COSIGN_BIN" ]]; then skip_or_fail "real cosign not available"; fi
    run "$COSIGN_BIN" download attestation --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"download attestation"* ]]
}

# --- bnd push arg vector (GitHub attestation store) ---

@test "run_verify: bnd push args target the store repo with the signed VSA file" {
    local vsa="$TEST_DIR/vsa.jsonl"
    mapfile -t args < <(wrangle_bnd_push_args "owner/repo" "$vsa")
    [[ "${args[0]}" == "push" ]]
    [[ "${args[1]}" == "github" ]]
    # The org/repo is positional, then the bundle file.
    [[ "${args[2]}" == "owner/repo" ]]
    [[ "${args[3]}" == "$vsa" ]]
}

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

# --- bundle seeding ---

@test "run_verify: seed copies the provenance JSONL when no OCI target" {
    printf 'PROVLINE\n' > "$BUNDLE_IN"
    export OCI_TARGET=""
    local seed="$TEST_DIR/seed.jsonl"
    wrangle_seed_bundle "$seed"
    [[ "$(cat "$seed")" == "PROVLINE" ]]
    # BUNDLE_IN stays intact so a re-run starts from the same base.
    [[ "$(cat "$BUNDLE_IN")" == "PROVLINE" ]]
}

# Emit a DSSE-enveloped JSONL line whose decoded payload carries $1 as its
# predicateType — the shape cosign download returns for an OCI referrer.
_dsse_line() {
    local payload
    payload="$(printf '{"predicateType":"%s","subject":[]}' "$1" | base64 | tr -d '\n')"
    printf '{"dsseEnvelope":{"payload":"%s"}}\n' "$payload"
}

@test "run_verify: seed fetches provenance via cosign download for an OCI target" {
    {
        printf '#!/bin/bash\n'
        printf '[[ "$1" == "download" && "$2" == "attestation" ]] || exit 1\n'
        printf 'cat %q\n' "$TEST_DIR/referrers.jsonl"
    } > "$TEST_DIR/cosign"
    chmod +x "$TEST_DIR/cosign"
    _dsse_line "https://slsa.dev/provenance/v1" > "$TEST_DIR/referrers.jsonl"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    local seed="$TEST_DIR/seed.jsonl"
    wrangle_seed_bundle "$seed"
    # Exactly the one provenance line, with its predicateType preserved.
    [[ "$(wc -l < "$seed")" -eq 1 ]]
    [[ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicateType' "$seed")" == "https://slsa.dev/provenance/v1" ]]
}

@test "run_verify: seed drops a prior VSA referrer so a re-run stays idempotent" {
    # cosign download returns ALL referrers; a prior verify run left a VSA on the
    # digest. Seeding must keep only the provenance so the rebuilt bundle never
    # accumulates the stale VSA (and re-appends exactly one fresh VSA per subject).
    {
        printf '#!/bin/bash\n'
        printf '[[ "$1" == "download" && "$2" == "attestation" ]] || exit 1\n'
        printf 'cat %q\n' "$TEST_DIR/referrers.jsonl"
    } > "$TEST_DIR/cosign"
    chmod +x "$TEST_DIR/cosign"
    {
        _dsse_line "https://slsa.dev/provenance/v1"
        _dsse_line "https://slsa.dev/verification_summary/v1"
    } > "$TEST_DIR/referrers.jsonl"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    local seed="$TEST_DIR/seed.jsonl"
    wrangle_seed_bundle "$seed"
    [[ "$(wc -l < "$seed")" -eq 1 ]]
    [[ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicateType' "$seed")" == "https://slsa.dev/provenance/v1" ]]
}

@test "run_verify: seed fails closed when no provenance referrer is present" {
    # A digest that carries only VSAs (no provenance) must not seed an empty
    # bundle — that would silently drop the provenance the VSAs append to.
    {
        printf '#!/bin/bash\n'
        printf '[[ "$1" == "download" && "$2" == "attestation" ]] || exit 1\n'
        printf 'cat %q\n' "$TEST_DIR/referrers.jsonl"
    } > "$TEST_DIR/cosign"
    chmod +x "$TEST_DIR/cosign"
    _dsse_line "https://slsa.dev/verification_summary/v1" > "$TEST_DIR/referrers.jsonl"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    run wrangle_seed_bundle "$TEST_DIR/seed.jsonl"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no SLSA provenance referrer"* ]]
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

@test "run_verify: emit pipes ampel output through the HTML sanitizer" {
    # Stub ampel emits HTML so we can confirm tags are stripped on the way to
    # the summary (real ampel needs valid attestations to produce a report).
    cat > "$TEST_DIR/ampel" <<'STUB'
#!/bin/bash
printf '<h1>PASS</h1><script>x</script>RESULT\n'
STUB
    chmod +x "$TEST_DIR/ampel"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"

    run wrangle_verify_emit_vsa "sha256:abc" "$VSA"
    [[ "$status" -eq 0 ]]
    summary="$(cat "$GITHUB_STEP_SUMMARY")"
    [[ "$summary" == *"PASS"* ]]
    [[ "$summary" == *"RESULT"* ]]
    [[ "$summary" != *"<h1>"* ]]
    [[ "$summary" != *"<script>"* ]]
}

@test "run_verify: emit preserves a PASS verdict when the report exceeds the summary cap" {
    # Regression: a >MAX_SUMMARY report must not SIGPIPE the sanitizer and flip
    # a passing verdict into a blocked release.
    cat > "$TEST_DIR/ampel" <<'STUB'
#!/bin/bash
head -c 200000 /dev/zero | tr '\0' 'a'
exit 0
STUB
    chmod +x "$TEST_DIR/ampel"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"

    run wrangle_verify_emit_vsa "sha256:abc" "$VSA"
    [[ "$status" -eq 0 ]]
    # Summary is truncated to the cap, but the verdict still passed.
    [[ "$(wc -c < "$GITHUB_STEP_SUMMARY")" -le 65536 ]]
}

@test "run_verify: emit propagates a failing ampel exit code" {
    cat > "$TEST_DIR/ampel" <<'STUB'
#!/bin/bash
printf 'FAILED\n'
exit 1
STUB
    chmod +x "$TEST_DIR/ampel"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"

    run wrangle_verify_emit_vsa "sha256:abc" "$VSA"
    [[ "$status" -ne 0 ]]
}

@test "run_verify: run rejects an input that fails validation (fail-closed)" {
    # Run the SCRIPT (set -e active) so a bad input hard-fails at validation
    # before ampel — `run <function>` would disable errexit and fall through.
    export SUBJECTS='bad;rm -rf /'
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    : > "$BUNDLE_IN"
    run "$SCRIPT" run
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid subject"* ]]
    [[ "$output" != *"command not found"* ]]
}

# --- run composition: per-subject emit -> sign -> append ---

@test "run_verify: run emits, signs, and appends one VSA line per subject" {
    # Stub ampel/bnd so each subject produces a deterministic signed line; the
    # bundle = the seeded provenance lines plus one appended VSA per subject.
    cat > "$TEST_DIR/ampel" <<STUB
#!/bin/bash
# Emit a one-line JSON unsigned VSA naming the subject, where --results-path points.
# File subjects are hashed by run_verify to --subject-hash; echo that back so the
# test can prove the per-subject VSA reached the bundle and the store.
subj=""
for a in "\$@"; do case "\$a" in --subject-hash=*) subj="\${a#--subject-hash=}";; --subject=*) subj="\${a#--subject=}";; esac; done
for a in "\$@"; do case "\$a" in --results-path=*) printf '{"unsigned":"%s"}\n' "\$subj" > "\${a#--results-path=}";; esac; done
printf 'report\n'
STUB
    # bnd "signs" (statement) by wrapping the unsigned statement over two lines
    # (so the jq -c flatten in run is load-bearing); "push" records the VSA it
    # was handed so the test can prove the signed statement reached the store.
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
if [[ "\$1" == "push" ]]; then cat "\$4" >> "$TEST_DIR/pushed"; exit 0; fi
printf '{\n  "signed": '; cat "\$2"; printf '}\n'
STUB
    chmod +x "$TEST_DIR/ampel" "$TEST_DIR/bnd"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    : > "$TEST_DIR/pushed"
    printf '{"provenance":1}\n' > "$BUNDLE_IN"
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

    run "$SCRIPT" run
    [[ "$status" -eq 0 ]]
    # One per-artifact bundle per subject, named <artifact-basename>.intoto.jsonl.
    local a="$BUNDLE_OUT/a.tgz.intoto.jsonl" b="$BUNDLE_OUT/b.whl.intoto.jsonl"
    [[ -f "$a" && -f "$b" ]]
    # Each subject's signed VSA (keyed by its sha256) was posted to the store.
    grep -q "\"signed\":{\"unsigned\":\"$ha\"}" "$TEST_DIR/pushed"
    grep -q "\"signed\":{\"unsigned\":\"$hb\"}" "$TEST_DIR/pushed"
    # Each bundle is the seeded provenance line plus exactly that subject's VSA.
    [[ "$(wc -l < "$a")" -eq 2 ]]
    [[ "$(wc -l < "$b")" -eq 2 ]]
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

@test "run_verify: run pushes only the VSA statement as the referrer for an OCI target" {
    # Container path: provenance fetched via cosign download; the combined
    # provenance+VSA bundle is written for the workflow artifact, but only the
    # lone signed VSA statement is pushed as the by-digest referrer (cosign
    # attach rejects a multi-line bundle).
    cat > "$TEST_DIR/ampel" <<STUB
#!/bin/bash
for a in "\$@"; do case "\$a" in --results-path=*) printf '{"vsa":1}\n' > "\${a#--results-path=}";; esac; done
printf 'report\n'
STUB
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
[[ "\$1" == "push" ]] && exit 0
cat "\$2"
STUB
    # download returns a real provenance DSSE envelope so the seed filter keeps it.
    _dsse_line "https://slsa.dev/provenance/v1" > "$TEST_DIR/referrers.jsonl"
    # Record the verb plus, for attach, the file cosign was handed so the test
    # can prove it was the single VSA statement, not the multi-line bundle.
    {
        printf '#!/bin/bash\n'
        printf 'printf "%%s\\n" "$1" >> %q\n' "$TEST_DIR/cosign-calls"
        printf '[[ "$1" == "download" ]] && { cat %q; exit 0; }\n' "$TEST_DIR/referrers.jsonl"
        printf 'if [[ "$1" == "attach" ]]; then\n'
        printf '  for a in "$@"; do prev="${prev:-}"; [[ "$prev" == "--attestation" ]] && cp "$a" %q; prev="$a"; done\n' "$TEST_DIR/attached"
        printf 'fi\n'
        printf 'exit 0\n'
    } > "$TEST_DIR/cosign"
    chmod +x "$TEST_DIR/ampel" "$TEST_DIR/bnd" "$TEST_DIR/cosign"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    export SUBJECTS="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"

    run "$SCRIPT" run
    [[ "$status" -eq 0 ]]
    # cosign was called to download the provenance AND to attach the VSA.
    grep -qx "download" "$TEST_DIR/cosign-calls"
    grep -qx "attach" "$TEST_DIR/cosign-calls"
    # The combined bundle (workflow artifact) = provenance line + VSA line.
    local bundle="$BUNDLE_OUT/sha256-0000000000000000000000000000000000000000000000000000000000000000.intoto.jsonl"
    [[ -f "$bundle" ]]
    [[ "$(wc -l < "$bundle")" -eq 2 ]]
    # The referrer push got ONLY the lone VSA statement — a single line, no
    # provenance — so cosign attach accepts it.
    [[ "$(wc -l < "$TEST_DIR/attached")" -eq 1 ]]
    grep -q '"vsa":1' "$TEST_DIR/attached"
    ! grep -q 'dsseEnvelope' "$TEST_DIR/attached"
}

@test "run_verify: run fails closed when the VSA referrer push fails" {
    # The by-digest VSA referrer is the container consumer's discovery path, so a
    # failing cosign attach (after the one transient retry) must fail the verify
    # job — a missing by-digest VSA is a real delivery gap, not a nice-to-have.
    cat > "$TEST_DIR/ampel" <<STUB
#!/bin/bash
for a in "\$@"; do case "\$a" in --results-path=*) printf '{"vsa":1}\n' > "\${a#--results-path=}";; esac; done
printf 'report\n'
STUB
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
[[ "\$1" == "push" ]] && exit 0
cat "\$2"
STUB
    _dsse_line "https://slsa.dev/provenance/v1" > "$TEST_DIR/referrers.jsonl"
    # download succeeds (seeds the provenance); attach fails persistently.
    {
        printf '#!/bin/bash\n'
        printf '[[ "$1" == "download" ]] && { cat %q; exit 0; }\n' "$TEST_DIR/referrers.jsonl"
        printf '[[ "$1" == "attach" ]] && exit 7\n'
        printf 'exit 0\n'
    } > "$TEST_DIR/cosign"
    chmod +x "$TEST_DIR/ampel" "$TEST_DIR/bnd" "$TEST_DIR/cosign"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    export SUBJECTS="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"

    run "$SCRIPT" run
    [[ "$status" -ne 0 ]]
}

# --- build-metadata (SBOM) statement emission ---

@test "run_verify: emit_metadata is a no-op when METADATA_ROOT is unset" {
    # npm/go/python/container without a metadata dir: nothing is appended and the
    # engine isn't invoked. A wrangle-attest stub that fails proves the path
    # returns 0 untouched.
    cat > "$TEST_DIR/wrangle-attest" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$TEST_DIR/wrangle-attest"
    export PATH="$TEST_DIR:$PATH"
    unset METADATA_ROOT
    local bundle="$TEST_DIR/bundle.jsonl"
    printf '{"provenance":1}\n' > "$bundle"
    run wrangle_emit_metadata_statements "sha256:$(printf '0%.0s' {1..64})" "$bundle"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$bundle")" -eq 1 ]]
}

@test "run_verify: emit_metadata appends and pushes the engine's signed statement" {
    # The engine signs keyless (network/OIDC), so a stub wrangle-attest emits a
    # deterministic compact signed line — this exercises the shell glue (append +
    # store + referrer), not the engine (Go-unit-tested; dispatch-e2e for keyless).
    cat > "$TEST_DIR/wrangle-attest" <<STUB
#!/bin/bash
subj=""
for a in "\$@"; do case "\$a" in --subject=*) subj="\${a#--subject=}";; --out=*) out="\${a#--out=}";; esac; done
printf '{"signedStatement":{"predicateType":"https://spdx.dev/Document","subject":[{"digest":{"sha256":"%s"}}]}}\n' "\${subj#sha256:}" > "\$out"
STUB
    # push records the file it was handed so store delivery is provable.
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
[[ "\$1" == "push" ]] && { cat "\$4" >> "$TEST_DIR/pushed"; exit 0; }
exit 0
STUB
    chmod +x "$TEST_DIR/wrangle-attest" "$TEST_DIR/bnd"
    export PATH="$TEST_DIR:$PATH"
    export METADATA_ROOT="$TEST_DIR/meta"; mkdir -p "$METADATA_ROOT"
    export GITHUB_REPOSITORY="o/r"
    export OCI_TARGET=""
    : > "$TEST_DIR/pushed"
    local bundle="$TEST_DIR/bundle.jsonl"
    printf '{"provenance":1}\n' > "$bundle"
    local sha; sha="$(printf '0%.0s' {1..64})"
    run wrangle_emit_metadata_statements "sha256:$sha" "$bundle"
    [[ "$status" -eq 0 ]]
    # Seeded provenance line plus exactly one appended signed statement.
    [[ "$(wc -l < "$bundle")" -eq 2 ]]
    [[ "$(tail -1 "$bundle" | jq -r '.signedStatement.predicateType')" == "https://spdx.dev/Document" ]]
    # The signed statement reached the store, bound to the single sha256 subject.
    [[ "$(jq -r '.signedStatement.subject[0].digest.sha256' "$TEST_DIR/pushed")" == "$sha" ]]
}

@test "run_verify: emit_metadata hands a file subject to the engine via --artifact" {
    # go/npm/python subjects are dist files: the engine self-digests them via
    # --artifact, so the shell passes the path, never a precomputed digest.
    cat > "$TEST_DIR/wrangle-attest" <<STUB
#!/bin/bash
for a in "\$@"; do case "\$a" in --out=*) out="\${a#--out=}";; esac; done
printf '%s\n' "\$@" > "$TEST_DIR/attest-args"
printf '{"signedStatement":1}\n' > "\$out"
STUB
    chmod +x "$TEST_DIR/wrangle-attest"
    export PATH="$TEST_DIR:$PATH"
    export METADATA_ROOT="$TEST_DIR/meta"; mkdir -p "$METADATA_ROOT"
    export OCI_TARGET=""
    cat > "$TEST_DIR/bnd" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$TEST_DIR/bnd"
    mkdir -p "$TEST_DIR/dist"; printf 'AAA\n' > "$TEST_DIR/dist/a.tgz"
    local bundle="$TEST_DIR/bundle.jsonl"; printf '{"provenance":1}\n' > "$bundle"
    run wrangle_emit_metadata_statements "$TEST_DIR/dist/a.tgz" "$bundle"
    [[ "$status" -eq 0 ]]
    grep -qx -- "--artifact=$TEST_DIR/dist/a.tgz" "$TEST_DIR/attest-args"
    ! grep -q -- "--subject=" "$TEST_DIR/attest-args"
}

@test "run_verify: emit_metadata fails closed when the real engine sees a malformed manifest" {
    # The real engine fails closed at discoverManifests — before newSigner — so a
    # malformed top-level manifest aborts hermetically (no OIDC/network). Drive
    # the real binary to prove genuine engine fail-closed, not a stubbed exit.
    if [[ ! -x "$ATTEST_BIN" ]]; then skip_or_fail "real wrangle-attest not available"; fi
    local dir="$TEST_DIR/wrangle-attest-bin"; mkdir -p "$dir"
    ln -sf "$ATTEST_BIN" "$dir/wrangle-attest"
    export PATH="$dir:$PATH"
    export METADATA_ROOT="$TEST_DIR/meta"; mkdir -p "$METADATA_ROOT"
    export WRANGLE_RETRY_DELAY=0
    printf 'not json\n' > "$METADATA_ROOT/wrangle_attestation_metadata.json"
    local bundle="$TEST_DIR/bundle.jsonl"; printf '{"provenance":1}\n' > "$bundle"
    run wrangle_emit_metadata_statements "sha256:$(printf '0%.0s' {1..64})" "$bundle"
    [[ "$status" -ne 0 ]]
    # Nothing appended: the seeded provenance line is untouched.
    [[ "$(wc -l < "$bundle")" -eq 1 ]]
}

# --- attach to release (wrangle_attach_release) ---
#
# wrangle attaches the bundle only when a release already exists; it never
# creates one. These tests drive a `gh` shim whose `release view` exit code
# follows GH_VIEW_SEQ so both branches (release present / absent) are exercised.

# Install a gh shim on PATH that logs calls and returns scripted exit codes.
_install_gh_shim() {
    cat > "$TEST_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "release view")
    n=$(cat "$GH_VIEW_N" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$GH_VIEW_N"
    code=$(printf '%s' "$GH_VIEW_SEQ" | cut -d' ' -f"$n"); exit "${code:-1}" ;;
  "release create") exit "${GH_CREATE_CODE:-0}" ;;
  "release upload") exit "${GH_UPLOAD_CODE:-0}" ;;
esac
exit 0
SHIM
    chmod +x "$TEST_DIR/gh"
    export PATH="$TEST_DIR:$PATH"
    export GH_LOG="$TEST_DIR/gh.log"; : > "$GH_LOG"
    export GH_VIEW_N="$TEST_DIR/gh.viewn"; : > "$GH_VIEW_N"
    export GITHUB_REF_NAME="v1.2.3"
}

@test "run_verify attach: every per-artifact bundle is uploaded to the existing release" {
    _install_gh_shim
    mkdir -p "$BUNDLE_OUT"
    : > "$BUNDLE_OUT/a.tgz.intoto.jsonl"
    : > "$BUNDLE_OUT/b.whl.intoto.jsonl"
    export GH_VIEW_SEQ="0"            # first view succeeds (release exists)
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    grep -qx "release upload v1.2.3 $BUNDLE_OUT/a.tgz.intoto.jsonl --clobber" "$GH_LOG"
    grep -qx "release upload v1.2.3 $BUNDLE_OUT/b.whl.intoto.jsonl --clobber" "$GH_LOG"
    ! grep -q "release create" "$GH_LOG"   # create must be skipped
}

@test "run_verify attach: missing release skips create and upload, exits 0" {
    _install_gh_shim
    mkdir -p "$BUNDLE_OUT"
    : > "$BUNDLE_OUT/a.tgz.intoto.jsonl"
    export GH_VIEW_SEQ="1"            # view fails (no release)
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]            # no release is not an error — bundle stays the artifact
    [[ "$output" == *"workflow artifact only"* ]]
    if grep -q "release create" "$GH_LOG"; then return 1; fi
    if grep -q "release upload" "$GH_LOG"; then return 1; fi
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

@test "retry: ampel and bnd invocations both route through wrangle_retry_once" {
    grep -q 'wrangle_retry_once "$report" ampel' "$SCRIPT"
    grep -q 'wrangle_retry_once "$vsa" bnd' "$SCRIPT"
}
