#!/usr/bin/env bats

# Tests for the verify-vsa composite action. Three flavors:
#
#   - Behavioral: run verify_vsa.sh with an `ampel` shim on PATH that
#     records its argv and snapshots the policy it was handed. A shim is
#     required because a real `ampel verify` needs Sigstore (Fulcio/Rekor)
#     plus a real keyless VSA for the exact file digest — that lives in
#     test/consumer/verify_consumer_vsa.bats, which runs this script
#     end-to-end against the real fixtures with real ampel. The gate
#     PolicySet's own verdict logic and identity enforcement are covered
#     with real ampel in policies/test.bats.
#   - Structural: fingerprints on action.yml so a drive-by edit can't
#     silently drop the env passthrough, the pinned installer/download
#     steps, or the script delegation.
#   - Contract: divergence-fail guards tying this consumer to its
#     producers (the VSA artifact-name convention in actions/verify and the
#     consumer PolicySet's identity). The ampel version needs no guard: the
#     action builds from tools/go.mod, the single source actions/verify uses.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    SCRIPT="$ACTION_DIR/verify_vsa.sh"
    GATE_POLICY="$ACTION_DIR/../../policies/wrangle-vsa-gate-v1.hjson"
    TMP="$(mktemp -d)"
    AMPEL_LOG="$TMP/ampel_calls.log"
    POLICY_SNAPSHOT="$TMP/policy_used.hjson"
    VSAS="$TMP/vsas"
    mkdir -p "$VSAS"

    # Records argv and snapshots the --policy file: the script derives a
    # narrowed policy into a temp dir its EXIT trap removes, so the content
    # must be captured at call time to be assertable.
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/ampel" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$AMPEL_LOG"
prev=""
for arg in "\$@"; do
    if [[ "\$prev" == "--policy" ]]; then cp "\$arg" "$POLICY_SNAPSHOT"; fi
    prev="\$arg"
done
exit "\${AMPEL_SHIM_EXIT:-0}"
EOF
    chmod +x "$TMP/bin/ampel"
    PATH="$TMP/bin:$PATH"
}

teardown() { rm -rf "$TMP"; }

# A VSA file only has to exist for the dispatch tests — the shim never reads
# it; verdict logic runs against real VSAs in policies/test.bats and
# test/consumer/verify_consumer_vsa.bats.
make_vsa() {
    printf '{"dsseEnvelope":{"payload":""}}\n' > "$VSAS/$1.intoto.jsonl"
}

# --- input validation ---

@test "behavior: fails without ARTIFACT_PATH" {
    ARTIFACT_PATH="" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"ARTIFACT_PATH is required"* ]]
}

@test "behavior: fails on nonexistent path" {
    ARTIFACT_PATH="$TMP/missing" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"no such file or directory"* ]]
}

@test "behavior: rejects malformed REPO" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="not-a-repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"REPO must be <owner>/<repo>"* ]]
}

@test "behavior: rejects missing VSA_DIR" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$TMP/nope" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"VSA_DIR is not a directory"* ]]
}

@test "behavior: rejects malformed SIGNER_WORKFLOW" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" \
        SIGNER_WORKFLOW='owner/repo/wf.yml; rm -rf /' run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"SIGNER_WORKFLOW must be"* ]]
}

@test "behavior: fails when ampel is not on PATH" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz"
    # PATH pinned to system dirs only: the dev machine may carry a real ampel
    # somewhere on PATH, and env.sh re-adds only WRANGLE_BIN_DIR (empty here).
    PATH="/usr/bin:/bin" WRANGLE_BIN_DIR="$TMP/nobin" \
        ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" \
        run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"ampel not found"* ]]
}

@test "behavior: refuses an empty directory" {
    mkdir "$TMP/empty"
    ARTIFACT_PATH="$TMP/empty" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"refusing to pass an empty set"* ]]
}

@test "behavior: enumeration failure fails closed, not silent-subset" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a.tgz"
    make_vsa "a.tgz"
    # A find that emits some entries and then dies (unreadable subdir,
    # I/O error) must fail the run, not verify the readable subset.
    cat > "$TMP/bin/find" <<EOF
#!/usr/bin/env bash
printf 'partial\0'
exit 1
EOF
    chmod +x "$TMP/bin/find"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"failed to enumerate"* ]]
    [[ ! -f "$AMPEL_LOG" ]]
}

# --- verification dispatch ---

@test "behavior: file with no VSA fails closed before any ampel call" {
    touch "$TMP/a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no VSA found for"* ]]
    [[ ! -f "$AMPEL_LOG" ]]
}

@test "behavior: verifies via the gate policy, binding subject, VSA, and origin repo" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 1 ]]
    grep -q -- "verify --subject $TMP/a.tgz" "$AMPEL_LOG"
    grep -q -- "--attestation $VSAS/a.tgz.intoto.jsonl" "$AMPEL_LOG"
    grep -q -- "--context sourceRepo:https://github.com/owner/repo" "$AMPEL_LOG"
    grep -q -- "wrangle-vsa-gate-v1.hjson" "$AMPEL_LOG"
    # The shipped policy is handed over untouched.
    diff -q "$POLICY_SNAPSHOT" "$GATE_POLICY"
    [[ "$output" == *"1 file(s) verified against PASSED VSAs"* ]]
}

@test "behavior: SIGNER_WORKFLOW narrows the policy identity, fail-closed derivation" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz"
    ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" \
        SIGNER_WORKFLOW="TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml" \
        run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    # The derived policy carries exactly the narrowed identity, with the
    # broad build_and_publish_[a-z]+ regexp gone, and is otherwise the
    # shipped policy (same required sourceRepo context + repo binding).
    grep -qF 'identity: "^https://github\\.com/TomHennen/wrangle/\\.github/workflows/build_and_publish_npm\\.yml@.+$"' "$POLICY_SNAPSHOT"
    ! grep -q 'build_and_publish_\[a-z\]' "$POLICY_SNAPSHOT"
    grep -qF 'sourceRepositoryUriMatch: { fromContext: "sourceRepo" }' "$POLICY_SNAPSHOT"
    [[ "$(grep -c 'identity: "' "$POLICY_SNAPSHOT")" -eq 1 ]]
}

@test "behavior: fails closed when ampel rejects the VSA" {
    touch "$TMP/a.tgz"
    make_vsa "a.tgz"
    AMPEL_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/a.tgz" REPO="owner/repo" VSA_DIR="$VSAS" \
        SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

@test "behavior: verifies every file under a directory recursively, spaces included" {
    mkdir -p "$TMP/dist/nested"
    touch "$TMP/dist/a.whl" "$TMP/dist/b file.tar.gz" "$TMP/dist/nested/c.txt"
    make_vsa "a.whl"; make_vsa "b file.tar.gz"; make_vsa "c.txt"
    ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 3 ]]
    grep -q "b file.tar.gz" "$AMPEL_LOG"
    [[ "$output" == *"3 file(s) verified"* ]]
}

@test "behavior: stops at the first failing file" {
    mkdir "$TMP/dist"
    touch "$TMP/dist/a.tgz" "$TMP/dist/b.tgz"
    make_vsa "a.tgz"; make_vsa "b.tgz"
    AMPEL_SHIM_EXIT=1 ARTIFACT_PATH="$TMP/dist" REPO="owner/repo" VSA_DIR="$VSAS" \
        SIGNER_WORKFLOW="" run "$SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$(wc -l < "$AMPEL_LOG")" -eq 1 ]]
}

# --- contract (divergence-fail guards across producer/consumer files) ---

@test "contract: producer uploads VSAs under the name this action resolves" {
    # actions/verify uploads one artifact per dist file, named
    # <artifact-name>.intoto.jsonl with artifact-name = the dist basename
    # (matrix.artifact in the build workflows); this action downloads
    # *.intoto.jsonl and resolves per file by basename. A producer-side
    # rename must fail here before it strands every adopter publish job.
    PRODUCER="$ACTION_DIR/../verify/action.yml"
    grep -q 'name: ${{ inputs.artifact-name }}.intoto.jsonl' "$PRODUCER"
    grep -q 'pattern: "\*.intoto.jsonl"' "$ACTION"
    grep -q '.intoto.jsonl' "$SCRIPT"
    WF_DIR="$ACTION_DIR/../../.github/workflows"
    grep -q 'artifact-name: ${{ matrix.artifact }}' "$WF_DIR/build_and_publish_npm.yml"
    grep -q 'artifact-name: ${{ matrix.artifact }}' "$WF_DIR/build_and_publish_python.yml"
}

@test "contract: gate policy identity stays equivalent to the consumer policy identity" {
    # The gate is the pre-publish twin of the consumer check: same signer,
    # same origin-repo binding. If either policy's identity drifts, the
    # other's must too — or this fails.
    CONSUMER="$ACTION_DIR/../../policies/wrangle-vsa-consumer-v1.hjson"
    for field in 'issuer: "' 'identity: "' 'sourceRepositoryUriMatch: '; do
        gate_line="$(grep -F "$field" "$GATE_POLICY")"
        consumer_line="$(grep -F "$field" "$CONSUMER")"
        [[ -n "$gate_line" ]] && [[ -n "$consumer_line" ]]
        [[ "$gate_line" == "$consumer_line" ]]
    done
}

# --- structural ---

@test "structure: action.yml threads inputs through env, not interpolation" {
    grep -q 'ARTIFACT_PATH: ${{ inputs.path }}' "$ACTION"
    grep -q 'SIGNER_WORKFLOW: ${{ inputs.signer-workflow }}' "$ACTION"
    grep -q 'REPO: ${{ inputs.repo }}' "$ACTION"
}

@test "structure: action.yml provisions Go, builds ampel from the tool manifest, and downloads VSAs via pinned steps" {
    grep -Eq 'uses: actions/setup-go@[0-9a-f]{40}' "$ACTION"
    grep -q 'go-version-file: ${{ github.action_path }}/../../tools/go.mod' "$ACTION"
    grep -q 'install github.com/carabiner-dev/ampel/cmd/ampel' "$ACTION"
    grep -Eq 'uses: actions/download-artifact@[0-9a-f]{40}' "$ACTION"
    grep -q 'pattern: "\*.intoto.jsonl"' "$ACTION"
}

@test "structure: action.yml delegates to verify_vsa.sh" {
    grep -q 'verify_vsa.sh' "$ACTION"
}

@test "structure: action.yml validates inputs before installing anything" {
    first_run="$(grep -o 'run: .*\.sh"' "$ACTION" | head -1)"
    [[ "$first_run" == *validate_inputs.sh* ]]
}
