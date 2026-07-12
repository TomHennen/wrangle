#!/bin/bash
set -euo pipefail
set -f

# Demo run for the wrangle-attest CLI: drives the REAL binary over the
# checked-in fixture tree in testdata/demo (two dist files, a container digest,
# an SBOM + a SARIF metadata root, a SLSA provenance and a VSA), echoes every
# command as a user would type it, decodes what came out, and asserts the
# properties. The normalized transcript is diffed against testdata/demo.golden.txt.
#
# Signing is real: in CI the ambient GitHub OIDC token is exchanged at Fulcio; on
# a laptop the signer runs the standard Sigstore browser/device flow, so the
# identity on the cert is the human's.
#
# WRANGLE_DEMO_UPDATE_GOLDEN=1 rewrites the golden from this run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES="$SCRIPT_DIR/testdata/demo"
GOLDEN="$SCRIPT_DIR/testdata/demo.golden.txt"

CONTAINER_SUBJECT="sha256:1923631e35baf2fd56a54ceabea80af979e9ca59b597aa29f5fe679fe8ce8256"
SHA512_HEX="$(printf 'e%.0s' {1..128})"

FAILURES=0
DEMO_TMP=""

heading() {
    printf '\n=== %s\n' "$1"
}

note() {
    printf '# %s\n' "$1"
}

# Echo the command the way a user would type it: one flag per continuation line.
show_cmd() {
    printf '\n$ %s' "$1"
    shift
    local arg
    for arg in "$@"; do
        if [[ "$arg" == --* ]]; then
            printf ' \\\n    %s' "$arg"
        else
            printf ' %s' "$arg"
        fi
    done
    printf '\n'
}

# Run a command with its output shown indented, and report its exit code.
demo_exec() {
    show_cmd "$@"
    local rc=0
    set +e
    "$@" 2>&1 | sed 's/^/    /'
    rc="${PIPESTATUS[0]}"
    set -e
    printf '    [exit %d]\n' "$rc"
    return "$rc"
}

check() {
    if [[ "$2" == "$3" ]]; then
        printf 'check: %s: %s\n' "$1" "$2"
    else
        printf 'CHECK FAILED: %s: %s (want %s)\n' "$1" "$2" "$3"
        FAILURES=$((FAILURES + 1))
    fi
}

check_exit() {
    local label="$1" expected="$2"
    shift 2
    local rc=0
    demo_exec "$@" || rc=$?
    check "$label exits $expected" "$rc" "$expected"
}

statement_count() {
    wc -l < "$1" | tr -d ' '
}

present_or_absent() {
    if [[ -e "$1" ]]; then
        printf 'present\n'
    else
        printf 'absent\n'
    fi
}

# Decode one bundle line: its statement's predicateType, every subject digest it
# binds, and whether the line carries real keyless material.
describe_line() {
    local line="$1" index="$2" payload material
    payload="$(printf '%s' "$line" | jq -r '.dsseEnvelope.payload' | base64 -d)"
    material="$(printf '%s' "$line" | jq -r '
        [ (if .verificationMaterial.certificate.rawBytes then "fulcio-cert" else empty end),
          (if (.verificationMaterial.tlogEntries | length) > 0 then "rekor-entry" else empty end) ]
        | if length == 0 then "none (unsigned fixture)" else join(" + ") end')"
    printf '    %d. predicateType: %s\n' "$index" "$(printf '%s' "$payload" | jq -r '.predicateType')"
    printf '%s' "$payload" | jq -r '.subject[] | "       subject:       sha256:" + .digest.sha256'
    printf '       material:      %s\n' "$material"
}

describe_bundle() {
    local file="$1" line index=0
    printf '\n  %s  (%s statement(s))\n' "$(basename "$file")" "$(statement_count "$file")"
    while IFS= read -r line; do
        index=$((index + 1))
        describe_line "$line" "$index"
    done < "$file"
}

demo_offline() {
    heading "the input a user starts from"

    note "two release binaries and one container image digest:"
    demo_exec sha256sum dist/wrangle_0.1.0_linux_amd64 dist/wrangle_0.1.0_darwin_arm64
    printf '\n'
    note "subjects.txt - one subject per line, file paths are self-digested:"
    demo_exec cat subjects.txt
    printf '\n'
    note "each tool leaves a metadata root: its manifest plus its native result file"
    demo_exec cat meta/sbom/wrangle_attestation_metadata.json
    demo_exec cat meta/scan/wrangle_attestation_metadata.json

    heading "fail closed: a non-sha256 subject digest"

    note "the GitHub attestation store keys by sha256; a sha512 subject is refused,"
    note "not silently reinterpreted as a file path."
    printf 'sha512:%s\n' "$SHA512_HEX" > bad-subjects.txt
    check_exit "sha512 subject" 2 \
        wrangle-attest assemble \
        --metadata-root meta/sbom \
        --metadata-root meta/scan \
        --subjects-file bad-subjects.txt \
        --provenance provenance/provenance.fixture.intoto.jsonl \
        --sign \
        --bundle-dir bundles \
        --statements-out statements.jsonl

    heading "fail closed: two subjects that collide on one bundle name"

    note "bundle names are basenames, so a rebuilt artifact under another directory"
    note "would clobber the first bundle. Refused before anything is signed."
    demo_exec cat colliding-subjects.txt
    check_exit "duplicate bundle name" 2 \
        wrangle-attest assemble \
        --metadata-root meta/sbom \
        --subjects-file colliding-subjects.txt \
        --provenance provenance/provenance.fixture.intoto.jsonl \
        --sign \
        --bundle-dir bundles \
        --statements-out statements.jsonl

    heading "fail closed: a manifest naming an unknown predicate type"

    demo_exec cat meta-broken/wrangle_attestation_metadata.json
    check_exit "unknown predicate-type" 2 \
        wrangle-attest assemble \
        --metadata-root meta-broken \
        --subjects-file subjects.txt \
        --provenance provenance/provenance.fixture.intoto.jsonl \
        --sign \
        --bundle-dir bundles \
        --statements-out statements.jsonl

    check "no bundle directory was created" "$(present_or_absent bundles)" "absent"
}

demo_signed() {
    heading "sign the build's SLSA provenance"

    note "the provenance is normally handed over by the build; here the demo signs"
    note "the statement itself, so assemble gets a real Sigstore bundle line."
    demo_exec wrangle-attest \
        --sign \
        --statement provenance/provenance.statement.json \
        --out provenance/provenance.intoto.jsonl
    check "provenance bundle lines" "$(statement_count provenance/provenance.intoto.jsonl)" "1"

    heading "assemble: sign every tool's metadata, one bundle per artifact"

    demo_exec wrangle-attest assemble \
        --metadata-root meta/sbom \
        --metadata-root meta/scan \
        --subjects-file subjects.txt \
        --provenance provenance/provenance.intoto.jsonl \
        --commit 0f4f2b3d3b7a1c8e5d9a6b4c2e1f0a9b8c7d6e5f \
        --sign \
        --bundle-dir bundles \
        --statements-out statements.jsonl

    heading "what came out"

    demo_exec ls bundles
    check "bundles written" "$(find bundles -maxdepth 1 -type f | wc -l | tr -d ' ')" "3"
    check "newly signed statements" "$(statement_count statements.jsonl)" "6"

    note "every bundle: the shared provenance verbatim, then that artifact's own"
    note "signed statements. Decoded from the DSSE payload of each line."
    describe_bundle bundles/wrangle_0.1.0_linux_amd64.intoto.jsonl
    describe_bundle bundles/wrangle_0.1.0_darwin_arm64.intoto.jsonl
    describe_bundle "bundles/sha256-${CONTAINER_SUBJECT#sha256:}.intoto.jsonl"
    check "statements per bundle" \
        "$(statement_count bundles/wrangle_0.1.0_linux_amd64.intoto.jsonl)" "3"

    heading "sign the VSA and append it to the artifact's bundle"

    note "what actions/verify does after the policy passes: one process signs the"
    note "VSA and appends the identical signed line to that artifact's bundle."
    demo_exec wrangle-attest \
        --sign \
        --statement vsa/vsa.statement.json \
        --out vsa/vsa.intoto.jsonl \
        --append bundles/wrangle_0.1.0_linux_amd64.intoto.jsonl
    describe_bundle bundles/wrangle_0.1.0_linux_amd64.intoto.jsonl
    check "linux bundle after append" \
        "$(statement_count bundles/wrangle_0.1.0_linux_amd64.intoto.jsonl)" "4"
    check "darwin bundle untouched" \
        "$(statement_count bundles/wrangle_0.1.0_darwin_arm64.intoto.jsonl)" "3"

    heading "fail closed: append to a bundle that does not exist"

    check_exit "append to missing bundle" 2 \
        wrangle-attest \
        --sign \
        --statement vsa/vsa.statement.json \
        --out vsa/vsa2.intoto.jsonl \
        --append bundles/does_not_exist.intoto.jsonl
    check "no stray --out written" "$(present_or_absent vsa/vsa2.intoto.jsonl)" "absent"

    heading "re-running assemble refuses to clobber"

    check_exit "re-run over a populated bundle-dir" 2 \
        wrangle-attest assemble \
        --metadata-root meta/sbom \
        --metadata-root meta/scan \
        --subjects-file subjects.txt \
        --provenance provenance/provenance.intoto.jsonl \
        --sign \
        --bundle-dir bundles \
        --statements-out statements.jsonl
    check "linux bundle still intact" \
        "$(statement_count bundles/wrangle_0.1.0_linux_amd64.intoto.jsonl)" "4"
}

demo_body() {
    printf 'wrangle-attest demo run\n'
    printf 'signing is real: --sign signs against public-good Sigstore, which writes a\n'
    printf 'public Rekor transparency-log entry under the signing identity.\n'
    printf 'signatures, Fulcio certs and Rekor entries are never printed: they differ\n'
    printf 'every run. Everything below is deterministic.\n'

    demo_offline
    demo_signed

    heading "result"
    if [[ "$FAILURES" -eq 0 ]]; then
        printf 'all checks passed\n'
    else
        printf '%d check(s) FAILED\n' "$FAILURES"
        return 1
    fi
}

stage_fixtures() {
    local work="$1"
    cp -R "$FIXTURES/." "$work/"
    printf 'dist/wrangle_0.1.0_linux_amd64\ndist/wrangle_0.1.0_darwin_arm64\n%s\n' \
        "$CONTAINER_SUBJECT" > "$work/subjects.txt"
    printf 'dist/wrangle_0.1.0_linux_amd64\ndist-rebuild/wrangle_0.1.0_linux_amd64\n' \
        > "$work/colliding-subjects.txt"
}

main() {
    # shellcheck source=../../lib/env.sh
    source "$REPO_ROOT/lib/env.sh"

    # Sorted output (ls, discovery order) must not drift with the caller's locale.
    export LC_ALL=C

    DEMO_TMP="$(mktemp -d)"
    trap 'rm -rf "$DEMO_TMP"' EXIT
    local tmp="$DEMO_TMP"

    go -C "$REPO_ROOT/tools" build -o "$tmp/bin/wrangle-attest" ./wrangle-attest
    PATH="$tmp/bin:$PATH"

    local work="$tmp/demo"
    mkdir -p "$work"
    stage_fixtures "$work"

    local raw="$tmp/raw.txt" transcript="$tmp/transcript.txt" rc=0
    set +e
    (
        cd "$work"
        demo_body
    ) 2>&1 | tee "$raw"
    rc="${PIPESTATUS[0]}"
    set -e

    sed "s|$tmp|/tmp/wrangle-attest-demo|g" "$raw" > "$transcript"
    if [[ -n "${WRANGLE_DEMO_TRANSCRIPT:-}" ]]; then
        cp "$transcript" "$WRANGLE_DEMO_TRANSCRIPT"
    fi

    if [[ "$rc" -ne 0 ]]; then
        printf '\ndemo.sh: checks failed\n' >&2
        return 1
    fi

    if [[ "${WRANGLE_DEMO_UPDATE_GOLDEN:-0}" == "1" ]]; then
        cp "$transcript" "$GOLDEN"
        printf '\ndemo.sh: wrote %s\n' "$GOLDEN"
        return 0
    fi

    if [[ ! -f "$GOLDEN" ]]; then
        printf '\ndemo.sh: %s is missing; re-run with WRANGLE_DEMO_UPDATE_GOLDEN=1 to capture it.\n' "$GOLDEN" >&2
        return 1
    fi

    if ! diff -u "$GOLDEN" "$transcript"; then
        printf '\ndemo.sh: transcript does not match the golden.\n' >&2
        return 1
    fi
    printf '\ndemo.sh: transcript matches the golden.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
