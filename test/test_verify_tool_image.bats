#!/usr/bin/env bats

# Fail-closed pull-time VSA gate (#596): run.sh verifies a curated tool image's
# wrangle-signed PASSED verification-summary attestation BEFORE dispatching the
# container. These drive run.sh's image path up to (and including) the gate with
# a `gh` shim and a `docker` shim — a real attestation API and registry are
# unavailable in the hermetic unit suite, and the gate runs after the digest-pin
# regex but before any docker call, so the seam is exercised without either.
#
# The shim's PASSED JSON mirrors the shape of real `gh attestation verify
# --format json` (a JSON array; the verdict at
# .verificationResult.statement.predicate.verificationResult), captured from a
# live run against the curated osv image; the FAILED case mutates only the
# verdict, proving the jq — the sole verdict check — catches a non-PASSED VSA.

# A shared clean bin of symlinks to every real tool on PATH except gh and docker
# — the two the tests shim.
setup_file() {
    SHARED_BIN="$BATS_FILE_TMPDIR/bin"
    mkdir -p "$SHARED_BIN"
    local dir f name
    IFS=':' read -ra _path_dirs <<< "$PATH"
    for dir in "${_path_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -x "$f" && ! -d "$f" ]] || continue
            name="${f##*/}"
            [[ "$name" == gh || "$name" == docker ]] && continue
            [[ -e "$SHARED_BIN/$name" ]] || ln -s "$f" "$SHARED_BIN/$name"
        done
    done
    export SHARED_BIN
}

setup() {
    ORIG_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    RUN_SH="$ORIG_DIR/run.sh"
    TMP_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrangle-verify-img.XXXXXX")"
    SRC="$TMP_DIR/src"
    OUT="$TMP_DIR/out"
    TOOLS="$TMP_DIR/tools"
    CLEANBIN="$TMP_DIR/bin"
    EMPTYBIN="$TMP_DIR/empty-bin"
    GH_LOG="$TMP_DIR/gh.log"
    DOCKER_LOG="$TMP_DIR/docker.log"
    mkdir -p "$SRC" "$OUT" "$TOOLS/imgtool" "$CLEANBIN" "$EMPTYBIN"
    : > "$GH_LOG"
    : > "$DOCKER_LOG"

    # Writable overlay ahead of the shared farm holds the gh and docker shims, so
    # they are the only gh/docker on PATH. EMPTYBIN is WRANGLE_BIN_DIR (env.sh
    # prepends it) so it cannot reintroduce a real gh.
    CLEAN_PATH="$CLEANBIN:$SHARED_BIN"

    # docker shim: records its invocation and exits per DOCKER_SHIM_EXIT. A real
    # container never runs in the unit suite; dispatch is asserted by the log.
    cat > "$CLEANBIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${DOCKER_SHIM_LOG:-}" ]] && printf 'docker %s\n' "$*" >> "$DOCKER_SHIM_LOG"
exit "${DOCKER_SHIM_EXIT:-0}"
DOCKER
    chmod +x "$CLEANBIN/docker"

    export ORIG_DIR RUN_SH TMP_DIR SRC OUT TOOLS CLEANBIN EMPTYBIN GH_LOG DOCKER_LOG CLEAN_PATH
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

# gh shim: emulates `gh attestation verify --format json` shapes. GH_SHIM_MODE
# selects the case; the PASSED body is the real JSON shape, FAILED mutates only
# the verdict.
_install_gh_shim() {
    cat > "$CLEANBIN/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${GH_SHIM_LOG:-}" ]] && printf 'gh %s\n' "$*" >> "$GH_SHIM_LOG"
case "${GH_SHIM_MODE:-passed}" in
    unattested) printf 'Error: no attestations found\n' >&2; exit 1 ;;
    empty)      printf '[]\n' ;;
    failed|passed)
        verdict="PASSED"
        [[ "$GH_SHIM_MODE" == "failed" ]] && verdict="FAILED"
        cat <<JSON
[{"verificationResult":{"statement":{"predicateType":"https://slsa.dev/verification_summary/v1","subject":[{"digest":{"sha256":"c8abda59e3a64520128c427d2fe9bd223c27e0a2056181ead1b9d3c6a5fb3b75"}}],"predicate":{"verificationResult":"$verdict","resourceUri":"ghcr.io/tomhennen/wrangle/imgtool@sha256:c8abda59e3a64520128c427d2fe9bd223c27e0a2056181ead1b9d3c6a5fb3b75","verifiedLevels":["SLSA_BUILD_LEVEL_3"],"slsaVersion":"1.1"}}}}]
JSON
        ;;
esac
GH
    chmod +x "$CLEANBIN/gh"
}

# A digest-pinned curated image (wrangle namespace) so the gate applies.
_curated_image="ghcr.io/tomhennen/wrangle/imgtool@sha256:c8abda59e3a64520128c427d2fe9bd223c27e0a2056181ead1b9d3c6a5fb3b75"
# A digest-pinned adopter-override image (different namespace) the gate skips.
_adopter_image="ghcr.io/adopter/imgtool@sha256:c8abda59e3a64520128c427d2fe9bd223c27e0a2056181ead1b9d3c6a5fb3b75"

_catalog() {
    cat > "$TOOLS/catalog.json" <<JSON
{"tools":{"imgtool":{"kind":"scan","delivery":"image","image":"$1"}}}
JSON
}

_run_orch() {
    PATH="$CLEAN_PATH" WRANGLE_BIN_DIR="$EMPTYBIN" \
        GH_SHIM_LOG="$GH_LOG" DOCKER_SHIM_LOG="$DOCKER_LOG" \
        WRANGLE_TOOLS_DIR="$TOOLS" \
        run "$RUN_SH" -s "$SRC" -o "$OUT" "$@"
}

@test "verify gate: attested + PASSED -> proceeds to dispatch" {
    _install_gh_shim
    _catalog "$_curated_image"
    GH_SHIM_MODE=passed _run_orch imgtool
    [ "$status" -eq 0 ]
    grep -q "verified PASSED" <<< "$output"
    # The container WAS dispatched (docker shim ran).
    grep -q "^docker run" "$DOCKER_LOG"
}

@test "verify gate: unattested (gh rc != 0) -> fail closed, no dispatch" {
    _install_gh_shim
    _catalog "$_curated_image"
    GH_SHIM_MODE=unattested _run_orch imgtool
    [ "$status" -eq 2 ]
    grep -q "verification failed" <<< "$output"
    # Fail closed: the container must NOT have been dispatched.
    [ ! -s "$DOCKER_LOG" ]
}

@test "verify gate: attested but FAILED VSA (gh rc 0) -> fail closed, no dispatch" {
    # The footgun: gh returns rc 0 for a FAILED VSA; only the jq verdict check
    # catches it. Proves the gate is not theater.
    _install_gh_shim
    _catalog "$_curated_image"
    GH_SHIM_MODE=failed _run_orch imgtool
    [ "$status" -eq 2 ]
    grep -q "verification failed" <<< "$output"
    [ ! -s "$DOCKER_LOG" ]
}

@test "verify gate: empty JSON array -> fail closed, no dispatch" {
    _install_gh_shim
    _catalog "$_curated_image"
    GH_SHIM_MODE=empty _run_orch imgtool
    [ "$status" -eq 2 ]
    grep -q "verification failed" <<< "$output"
    [ ! -s "$DOCKER_LOG" ]
}

@test "verify gate: gh absent -> error, no dispatch" {
    # No gh shim installed; CLEANBIN excludes the host gh, so gh is truly absent.
    _catalog "$_curated_image"
    _run_orch imgtool
    [ "$status" -eq 2 ]
    grep -q "gh not found" <<< "$output"
    [ ! -s "$DOCKER_LOG" ]
}

@test "verify gate: WRANGLE_VERIFY_TOOL_IMAGES=0 -> skips verify and dispatches" {
    _install_gh_shim
    _catalog "$_curated_image"
    WRANGLE_VERIFY_TOOL_IMAGES=0 GH_SHIM_MODE=unattested _run_orch imgtool
    [ "$status" -eq 0 ]
    grep -q "verification disabled by configuration" <<< "$output"
    # gh was never consulted; the container was dispatched.
    [ ! -s "$GH_LOG" ]
    grep -q "^docker run" "$DOCKER_LOG"
}

@test "verify gate: non-curated namespace -> skips wrangle-identity gate and dispatches" {
    _install_gh_shim
    _catalog "$_adopter_image"
    # gh would PASS, but the gate must not even consult it for a non-wrangle image.
    GH_SHIM_MODE=passed _run_orch imgtool
    [ "$status" -eq 0 ]
    grep -q "not wrangle-identity-verified" <<< "$output"
    [ ! -s "$GH_LOG" ]
    grep -q "^docker run" "$DOCKER_LOG"
}
