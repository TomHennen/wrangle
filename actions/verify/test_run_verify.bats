#!/usr/bin/env bats

# Tests for actions/verify/run_verify.sh
#
# The arg-builder functions are validated against the shape the real ampel/bnd
# CLIs accept. Full keyless bnd signing needs OIDC and cannot run offline, so
# the sign path is checked at the argument-vector level only; the emit path is
# exercised end-to-end with a tiny ampel stub on PATH to confirm the
# HTML-sanitize-to-summary plumbing.
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

    export ARTIFACT_NAME="app-1.2.3.tgz"
    export SUBJECT="sha256:abc123"
    export POLICY="policies/release.json"
    export COLLECTOR="jsonl:./atts"
    export FAIL="true"
    export VSA="$TEST_DIR/app.intoto.jsonl"
    export CONTEXT=""
    export ATTESTATION=""
    export OCI_TARGET=""

    # shellcheck source=run_verify.sh
    source "$SCRIPT"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "run_verify: exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "run_verify: a policy locator passes through unresolved" {
    export POLICY="git+https://github.com/o/r@abc123#policies/x.hjson"
    mapfile -t args < <(wrangle_ampel_verify_args)
    printf '%s\n' "${args[@]}" | grep -qx -- "--policy=git+https://github.com/o/r@abc123#policies/x.hjson"
}

@test "run_verify: an absolute policy path passes through unresolved" {
    # The absolute-path arm fails SILENTLY if dropped (an absolute path would be
    # double-prefixed to $REPO_ROOT/abs/… and ampel would read the wrong file),
    # so it gets its own guard distinct from the locator case.
    export POLICY="/etc/wrangle/policy.hjson"
    mapfile -t args < <(wrangle_ampel_verify_args)
    printf '%s\n' "${args[@]}" | grep -qx -- "--policy=/etc/wrangle/policy.hjson"
}

# --- ampel arg vector ---

@test "run_verify: ampel args carry the core verify flags" {
    mapfile -t args < <(wrangle_ampel_verify_args)
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
    mapfile -t args < <(wrangle_ampel_verify_args)
    if printf '%s\n' "${args[@]}" | grep -qx -- "--context"; then return 1; fi
    if printf '%s\n' "${args[@]}" | grep -qx -- "--attestation"; then return 1; fi
}

@test "run_verify: ampel args include context and attestation when set" {
    export CONTEXT="buildPoint:git+https://github.com/o/r"
    export ATTESTATION="att.intoto.json"
    mapfile -t args < <(wrangle_ampel_verify_args)
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
    mapfile -t args < <(wrangle_ampel_verify_args)
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

# --- cosign attach arg vector (OCI VSA push) ---

@test "run_verify: cosign attach args push the VSA as an attestation referrer" {
    local target="ghcr.io/o/r/img@sha256:abc"
    mapfile -t args < <(wrangle_cosign_attach_args "$VSA" "$target")
    [[ "${args[0]}" == "attach" ]]
    [[ "${args[1]}" == "attestation" ]]
    # --attestation carries the signed VSA bundle; the image ref is positional.
    printf '%s\n' "${args[@]}" | grep -qx -- "--attestation"
    printf '%s\n' "${args[@]}" | grep -qx -- "$VSA"
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

@test "run_verify: push is a no-op when OCI_TARGET is empty" {
    # npm/go/python path: nothing on PATH should be invoked. A cosign stub that
    # fails proves push returns 0 without calling it.
    cat > "$TEST_DIR/cosign" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$TEST_DIR/cosign"
    export WRANGLE_BIN_DIR="$TEST_DIR"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET=""
    run wrangle_push_vsa
    [[ "$status" -eq 0 ]]
}

@test "run_verify: push invokes cosign attach with the OCI target" {
    # Stub cosign records its args so we confirm the VSA + target reach it.
    cat > "$TEST_DIR/cosign" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$TEST_DIR/cosign-args"
STUB
    chmod +x "$TEST_DIR/cosign"
    export WRANGLE_BIN_DIR="$TEST_DIR"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:abc"
    : > "$VSA"
    run wrangle_push_vsa
    [[ "$status" -eq 0 ]]
    recorded="$(cat "$TEST_DIR/cosign-args")"
    [[ "$recorded" == *"attach"* ]]
    [[ "$recorded" == *"attestation"* ]]
    [[ "$recorded" == *"$VSA"* ]]
    [[ "$recorded" == *"$OCI_TARGET"* ]]
}

@test "run_verify: push fails the step when cosign fails (fail-closed)" {
    cat > "$TEST_DIR/cosign" <<'STUB'
#!/bin/bash
exit 7
STUB
    chmod +x "$TEST_DIR/cosign"
    export WRANGLE_BIN_DIR="$TEST_DIR"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:abc"
    : > "$VSA"
    run wrangle_push_vsa
    [[ "$status" -ne 0 ]]
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
    export WRANGLE_BIN_DIR="$TEST_DIR"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"

    run wrangle_verify_emit_vsa
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
    export WRANGLE_BIN_DIR="$TEST_DIR"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"

    run wrangle_verify_emit_vsa
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
    export WRANGLE_BIN_DIR="$TEST_DIR"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"

    run wrangle_verify_emit_vsa
    [[ "$status" -ne 0 ]]
}

@test "run_verify: emit rejects an input that fails validation (fail-closed)" {
    # Run the SCRIPT (set -e active) so a bad input hard-fails at validation
    # before ampel — `run <function>` would disable errexit and fall through.
    export SUBJECT='bad;rm -rf /'
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    run "$SCRIPT" emit
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid subject"* ]]
    [[ "$output" != *"command not found"* ]]
}

# --- run ordering: emit -> sign -> push ---

@test "run_verify: run executes emit, then sign, then push in order" {
    # Stub ampel/bnd/cosign so each records its turn. ampel writes the unsigned
    # VSA, bnd "signs" it (mv-in-place shape preserved), cosign pushes — the
    # order file proves the composition matches the documented contract.
    cat > "$TEST_DIR/ampel" <<STUB
#!/bin/bash
printf 'emit\n' >> "$TEST_DIR/order"
# Emit the unsigned VSA where --results-path points (last token after =).
for a in "\$@"; do case "\$a" in --results-path=*) printf 'vsa\n' > "\${a#--results-path=}";; esac; done
printf 'report\n'
STUB
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
printf 'sign\n' >> "$TEST_DIR/order"
cat "\$2"
STUB
    cat > "$TEST_DIR/cosign" <<STUB
#!/bin/bash
printf 'push\n' >> "$TEST_DIR/order"
STUB
    chmod +x "$TEST_DIR/ampel" "$TEST_DIR/bnd" "$TEST_DIR/cosign"
    export WRANGLE_BIN_DIR="$TEST_DIR"
    export PATH="$TEST_DIR:$PATH"
    export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    # Must be digest-pinned with a full 64-hex sha256 — `run` validates inputs
    # before ampel, so a short digest would fail at the gate, not the ordering.
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"

    run "$SCRIPT" run
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$TEST_DIR/order")" == $'emit\nsign\npush' ]]
}

# --- attach to release (wrangle_attach_release) ---
#
# wrangle attaches the VSA only when a release already exists; it never creates
# one. These tests drive a `gh` shim whose `release view` exit code follows
# GH_VIEW_SEQ so both branches (release present / absent) are exercised.

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

@test "run_verify attach: existing release is uploaded to without create" {
    _install_gh_shim
    export GH_VIEW_SEQ="0"            # first view succeeds (release exists)
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]
    grep -qx "release upload v1.2.3 $VSA --clobber" "$GH_LOG"
    ! grep -q "release create" "$GH_LOG"   # create must be skipped
}

@test "run_verify attach: missing release skips create and upload, exits 0" {
    _install_gh_shim
    export GH_VIEW_SEQ="1"            # view fails (no release)
    run "$SCRIPT" attach
    [[ "$status" -eq 0 ]]            # no release is not an error — VSA stays the artifact
    [[ "$output" == *"workflow artifact only"* ]]
    if grep -q "release create" "$GH_LOG"; then return 1; fi
    if grep -q "release upload" "$GH_LOG"; then return 1; fi
}
