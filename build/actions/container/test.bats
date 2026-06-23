#!/usr/bin/env bats

# Structural tests for build/actions/container/action.yml.
#
# Covers input-validation hardening specific to this action that
# neither zizmor nor actionlint check directly.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
    GITHUB_OUTPUT="$(mktemp)"
    export GITHUB_OUTPUT
}

teardown() {
    rm -f "$GITHUB_OUTPUT"
}

@test "container: validate_inputs.sh exists and is executable" {
    [[ -x "$ACTION_DIR/validate_inputs.sh" ]]
}

@test "container: validate_inputs.sh disables globbing with set -f" {
    # External input flows into the script; CLAUDE.md requires set -f.
    run grep '^set -f' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml delegates input validation to validate_inputs.sh" {
    run grep 'validate_inputs.sh' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: validate_inputs.sh rejects absolute path" {
    run "$ACTION_DIR/validate_inputs.sh" "/etc" "ghcr.io" "ghcr.io/owner/img" "enabled"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"path must be relative"* ]]
}

@test "container: validate_inputs.sh rejects traversal" {
    run "$ACTION_DIR/validate_inputs.sh" "../etc" "ghcr.io" "ghcr.io/owner/img" "enabled"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"traversal"* ]]
}

@test "container: validate_inputs.sh rejects bad registry" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "BAD;REGISTRY" "ghcr.io/owner/img" "enabled"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid registry"* ]]
}

@test "container: validate_inputs.sh rejects bad imagename" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "BAD IMAGE" "enabled"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid image name"* ]]
}

@test "container: validate_inputs.sh writes path/imagename/shortname to GITHUB_OUTPUT" {
    run "$ACTION_DIR/validate_inputs.sh" "pkg/foo" "ghcr.io" "ghcr.io/owner/img" "enabled"
    [[ "$status" -eq 0 ]]
    grep -q '^path=pkg/foo$' "$GITHUB_OUTPUT"
    grep -q '^imagename=ghcr.io/owner/img$' "$GITHUB_OUTPUT"
    grep -q '^shortname=pkg_foo$' "$GITHUB_OUTPUT"
}

@test "container: validate_inputs.sh at root '.' emits an empty shortname (clean names)" {
    run "$ACTION_DIR/validate_inputs.sh" "." "ghcr.io" "ghcr.io/owner/img" "enabled"
    [[ "$status" -eq 0 ]]
    grep -q '^shortname=$' "$GITHUB_OUTPUT"
}

# --- Build context / dockerfile selection (#596) ---

@test "container: default (no dockerfile) builds the <path> subdir as context, empty file" {
    # The self-contained-app-dir default: context is the path subdirectory's
    # own Dockerfile, file empty. This is the pre-#596 behavior and MUST be
    # byte-identical for existing callers.
    run "$ACTION_DIR/validate_inputs.sh" "pkg/foo" "ghcr.io" "ghcr.io/owner/img" "enabled"
    [[ "$status" -eq 0 ]]
    grep -qx 'context={{defaultContext}}:pkg/foo' "$GITHUB_OUTPUT"
    grep -qx 'file=' "$GITHUB_OUTPUT"
}

@test "container: empty dockerfile arg is treated as the default" {
    # An explicitly-empty dockerfile (the workflow passes "" by default) must
    # behave exactly like omitting it — context = path subdir, file empty.
    run "$ACTION_DIR/validate_inputs.sh" "pkg/foo" "ghcr.io" "ghcr.io/owner/img" "enabled" ""
    [[ "$status" -eq 0 ]]
    grep -qx 'context={{defaultContext}}:pkg/foo' "$GITHUB_OUTPUT"
    grep -qx 'file=' "$GITHUB_OUTPUT"
}

@test "container: dockerfile set builds the repo root as context with the Dockerfile at that subpath" {
    run "$ACTION_DIR/validate_inputs.sh" "tools/img" "ghcr.io" "ghcr.io/owner/img" "enabled" "tools/img/Dockerfile"
    [[ "$status" -eq 0 ]]
    grep -qx 'context={{defaultContext}}' "$GITHUB_OUTPUT"
    grep -qx 'file=tools/img/Dockerfile' "$GITHUB_OUTPUT"
    # path still drives shortname/metadata naming in the dockerfile case.
    grep -qx 'shortname=tools_img' "$GITHUB_OUTPUT"
}

@test "container: dockerfile input is validated — absolute path rejected" {
    run "$ACTION_DIR/validate_inputs.sh" "tools/img" "ghcr.io" "ghcr.io/owner/img" "enabled" "/etc/Dockerfile"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"path must be relative"* ]]
}

@test "container: dockerfile input is validated — traversal rejected" {
    run "$ACTION_DIR/validate_inputs.sh" "tools/img" "ghcr.io" "ghcr.io/owner/img" "enabled" "../../etc/Dockerfile"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"traversal"* ]]
}

@test "container: dockerfile input is validated — bad characters rejected" {
    run "$ACTION_DIR/validate_inputs.sh" "tools/img" "ghcr.io" "ghcr.io/owner/img" "enabled" 'tools/img/Docker;file'
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid characters in path"* ]]
}

@test "container: action.yml exposes a dockerfile input defaulting to empty" {
    run grep -E '^  dockerfile:' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  dockerfile:/,/^  [a-z]/p' \"$ACTION_DIR/action.yml\" | grep -E 'default:[[:space:]]*\"\"'"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml passes dockerfile to validate_inputs.sh" {
    run grep -E 'validate_inputs.sh.*INPUT_DOCKERFILE' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow exposes a dockerfile input and threads it to the composite" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^      dockerfile:' "$wf"
    [[ "$status" -eq 0 ]]
    run grep -F 'dockerfile: ${{ inputs.dockerfile }}' "$wf"
    [[ "$status" -eq 0 ]]
}

@test "container: build-push reads context and file from the normalize step (no inline {{defaultContext}} ternary)" {
    # context/file are computed in validate_inputs.sh and read back as step
    # outputs, never assembled with an inline GHA expression in the with:
    # block — that would force {{defaultContext}} brace-escaping and reopen
    # the template-injection surface this normalization closes.
    run grep -F 'context: ${{ steps.normalize.outputs.context }}' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    run grep -F 'file: ${{ steps.normalize.outputs.file }}' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # The old inline form must not creep back.
    run grep -F 'context: "{{defaultContext}}:${{ steps.normalize.outputs.path }}"' "$ACTION_DIR/action.yml"
    [[ "$status" -ne 0 ]]
}

# --- Cache gating (SLSA L3 isolation, #224 / SLSA_L3_AUDIT.md Finding 2) ---

@test "container: validate_inputs.sh accepts every cache policy value" {
    for mode in enabled disabled isolated read-only; do
        run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "ghcr.io/owner/img" "$mode"
        [[ "$status" -eq 0 ]]
    done
}

@test "container: validate_inputs.sh rejects an invalid cache value" {
    # A typo must fail loudly — silently leaving the cache on would
    # downgrade a release build from Build L3 to Build L2.
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "ghcr.io/owner/img" "disabeld"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid cache value"* ]]
}

@test "container: validate_inputs.sh rejects a missing cache argument" {
    run "$ACTION_DIR/validate_inputs.sh" "src" "ghcr.io" "ghcr.io/owner/img"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "container: action.yml exposes a cache input" {
    run grep -E '^  cache:' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml passes cache to validate_inputs.sh" {
    run grep -E 'validate_inputs.sh.*INPUT_CACHE' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: build-push reads cache-from/cache-to from the cacheflags step" {
    # The flags are resolved by the cacheflags step (resolve_cache.sh), not
    # by an inline GHA expression. A regressed action that hard-coded
    # `cache-from: type=gha` would turn caching ON for release builds —
    # the exact Build L3 downgrade the release gating prevents.
    run grep -F 'cache-from: ${{ steps.cacheflags.outputs.cache-from }}' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    run grep -F 'cache-to: ${{ steps.cacheflags.outputs.cache-to }}' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # No unconditional type=gha cache config may creep back.
    run grep -E '^[[:space:]]+cache-(from|to):[[:space:]]*type=gha' "$ACTION_DIR/action.yml"
    [[ "$status" -ne 0 ]]
}

@test "container: build-push suppresses the .dockerbuild build-record artifact" {
    # DOCKER_BUILD_RECORD_UPLOAD=false stops buildx uploading the ~-named
    # .dockerbuild bundle. DOCKER_BUILD_SUMMARY only drops the job summary,
    # not the artifact, so it is the wrong knob and must not be used instead.
    run grep -F 'DOCKER_BUILD_RECORD_UPLOAD: "false"' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: build job needs prep so it can read should-release" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$wf\" | grep -E 'needs:.*prep'"
    [[ "$status" -eq 0 ]]
}

@test "container: workflow has a scan job using the scan action" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E "^  scan:" "$wf"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$wf\" | grep -E 'uses:[[:space:]]*TomHennen/wrangle/actions/scan@'"
    [[ "$status" -eq 0 ]]
}

@test "container: scan steps are gated on scan-tools so empty disables scanning" {
    # scan-tools: "" skips the scan step; the scan job then concludes success
    # and never blocks the build/push.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$wf\" | grep -E \"if:.*inputs.scan-tools != ''\""
    [[ "$status" -eq 0 ]]
}

@test "container: scan job needs prep so go-cache can read should-release" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$wf\" | grep -E 'needs:.*prep'"
    [[ "$status" -eq 0 ]]
}

@test "container: scan job forces go-cache off on release" {
    # The scan gates the attested build; its Go tool cache must build cold on
    # release so a poisoned cache cannot forge a passing scan.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$wf\" | grep -E \"go-cache:.*should-release == 'true' && ''\""
    [[ "$status" -eq 0 ]]
}

@test "container: build job needs scan (load-bearing finding blocks the mid-composite push)" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$wf\" | grep -E 'needs:.*scan'"
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow forces cache disabled for release builds" {
    # Release builds MUST be cache-free: 'disabled' when should-release is
    # true, otherwise the adopter's pr-cache policy.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "grep -E \"cache:.*should-release.*'disabled'.*inputs.pr-cache\" \"$wf\""
    [[ "$status" -eq 0 ]]
}

# --- Adopter PR-to-PR cache knobs (#225 / SLSA_L3_AUDIT.md PR-to-PR section) ---

@test "container: resolve_cache.sh exists and is executable" {
    [[ -x "$ACTION_DIR/resolve_cache.sh" ]]
}

@test "container: resolve_cache.sh disables globbing with set -f" {
    # The scope argument is external (a branch name); CLAUDE.md requires set -f.
    run grep -E '^set -f' "$ACTION_DIR/resolve_cache.sh"
    [[ "$status" -eq 0 ]]
}

@test "container: resolve_cache.sh maps enabled to cache-from + cache-to" {
    run "$ACTION_DIR/resolve_cache.sh" "enabled" "main"
    [[ "$status" -eq 0 ]]
    grep -q '^cache-from=type=gha$' "$GITHUB_OUTPUT"
    grep -q '^cache-to=type=gha,mode=max$' "$GITHUB_OUTPUT"
}

@test "container: resolve_cache.sh maps disabled to empty flags" {
    run "$ACTION_DIR/resolve_cache.sh" "disabled" "main"
    [[ "$status" -eq 0 ]]
    grep -q '^cache-from=$' "$GITHUB_OUTPUT"
    grep -q '^cache-to=$' "$GITHUB_OUTPUT"
}

@test "container: resolve_cache.sh maps read-only to cache-from only (no cache-to)" {
    run "$ACTION_DIR/resolve_cache.sh" "read-only" "main"
    [[ "$status" -eq 0 ]]
    grep -q '^cache-from=type=gha$' "$GITHUB_OUTPUT"
    # cache-to must be empty: a read-only PR build never writes the cache.
    grep -q '^cache-to=$' "$GITHUB_OUTPUT"
}

@test "container: resolve_cache.sh maps isolated to a per-PR scope" {
    run "$ACTION_DIR/resolve_cache.sh" "isolated" "feature-x"
    [[ "$status" -eq 0 ]]
    grep -q '^cache-from=type=gha,scope=feature-x$' "$GITHUB_OUTPUT"
    grep -q '^cache-to=type=gha,mode=max,scope=feature-x$' "$GITHUB_OUTPUT"
}

@test "container: resolve_cache.sh sanitizes the scope against cache-config injection" {
    # The scope is a PR-author-controlled branch name flowing into a
    # comma-delimited cache config string. A comma/equals must not survive
    # to inject an extra cache option (e.g. ,type=registry,ref=evil).
    run "$ACTION_DIR/resolve_cache.sh" "isolated" 'x,type=registry,ref=evil/img'
    [[ "$status" -eq 0 ]]
    run grep -E '^cache-from=' "$GITHUB_OUTPUT"
    [[ "$output" != *",type=registry,"* ]]
    [[ "$output" != *"ref=evil"* ]]
}

@test "container: resolve_cache.sh rejects an invalid cache mode" {
    run "$ACTION_DIR/resolve_cache.sh" "bogus" "main"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid cache mode"* ]]
}

@test "container: action.yml resolves cache flags via resolve_cache.sh" {
    run grep -F 'resolve_cache.sh' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # The cacheflags step must run before the docker build.
    run bash -c "awk '/id: cacheflags/{c=NR} /uses: docker\\/build-push-action/{d=NR} END{exit !(c && d && c<d)}' \"$ACTION_DIR/action.yml\""
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow exposes the pr-cache input (default isolated)" {
    # Default is `isolated`, not `enabled`: a secure-by-default posture
    # that closes PR-to-PR cache poisoning out of the box while keeping
    # in-PR cache hits. Flipping this default back to `enabled` re-opens
    # the PR-to-PR poisoning vector for every adopter.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^      pr-cache:' "$wf"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^      pr-cache:/,/^      [a-z]/p' \"$wf\" | grep -E 'default:[[:space:]]*isolated'"
    [[ "$status" -eq 0 ]]
}

@test "container: composite cache input defaults to isolated" {
    # Direct callers of the composite (not a supported L3 path, but a
    # valid use) should also get the secure-by-default isolated scope.
    run bash -c "sed -n '/^  cache:/,/^  [a-z]/p' \"$ACTION_DIR/action.yml\" | grep -E 'default:[[:space:]]*\"isolated\"'"
    [[ "$status" -eq 0 ]]
}

@test "container: isolated scope is keyed by PR number, not branch name" {
    # Branch names are PR-author-controlled and can collide across forks
    # (two PRs from different forks both using `patch-1` would otherwise
    # share a cache scope). Keying on the GitHub-assigned PR number gives
    # each PR a unique, unforgeable scope. The non-PR fallback (push /
    # workflow_dispatch) is ref_name.
    run grep -F "github.event.pull_request.number && format('pr-{0}', github.event.pull_request.number) || github.ref_name" "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # The old head_ref-only form must not creep back.
    run grep -F 'github.head_ref || github.ref_name' "$ACTION_DIR/action.yml"
    [[ "$status" -ne 0 ]]
}

@test "container: README documents the pr-cache knob and the PR-to-PR threat" {
    run grep -F 'pr-cache' "$ACTION_DIR/README.md"
    [[ "$status" -eq 0 ]]
    run grep -iF 'PR-to-PR cache poisoning' "$ACTION_DIR/README.md"
    [[ "$status" -eq 0 ]]
}

# --- Unified metadata layout assertions (#150) ---

@test "container: action.yml derives the metadata dir via the shared lib" {
    run grep -E 'metadata_dir container' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: extract_sbom.sh writes the SBOM, the attest manifest, and the output" {
    # Fake docker so the test needs no real image; it echoes the SBOM JSON.
    fakebin="$(mktemp -d)"
    cat > "$fakebin/docker" << 'FAKE'
#!/usr/bin/env bash
printf '%s\n' '{"spdxVersion":"SPDX-2.3","name":"img"}'
FAKE
    chmod +x "$fakebin/docker"
    meta="$(mktemp -d)"
    out="$(mktemp)"
    PATH="$fakebin:$PATH" run "$ACTION_DIR/extract_sbom.sh" "img@sha256:abc" "$meta" "$out"
    [[ "$status" -eq 0 ]]
    run jq -e '.spdxVersion' "$meta/sbom.spdx.json"
    [[ "$status" -eq 0 ]]
    run jq -r '."predicate-type"' "$meta/wrangle_attestation_metadata.json"
    [[ "$output" == "https://spdx.dev/Document" ]]
    run jq -r '."result-file"' "$meta/wrangle_attestation_metadata.json"
    [[ "$output" == "sbom.spdx.json" ]]
    grep -Fq "sbom=$meta/sbom.spdx.json" "$out"
    rm -rf "$fakebin" "$meta" "$out"
}

@test "container: extract_sbom.sh usage error on wrong arg count" {
    run "$ACTION_DIR/extract_sbom.sh" "img@sha256:abc"
    [[ "$status" -eq 2 ]]
}

@test "container: action.yml exposes metadata-dir output" {
    run grep -E '^[[:space:]]+metadata-dir:' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml exposes shortname output" {
    run grep -E '^[[:space:]]+shortname:' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: action.yml derives the container-metadata artifact name via the shared lib" {
    run grep -E 'artifact_name container-metadata' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # Old name must not linger
    run grep 'container-build-results' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 1 ]]
}

@test "container: action.yml prepares metadata dir before SBOM extraction and upload" {
    # The standalone Prepare-metadata step must run BEFORE Extract-SBOM and
    # BEFORE the upload step, so the upload's path resolves to a real dir
    # even on `if: always()` after an earlier-step failure.
    run bash -c "awk '/Prepare metadata directory/{p=NR} /Extract SBOM from built image/{s=NR} /actions\\/upload-artifact/{u=NR} END{exit !(p && s && u && p<s && p<u)}' \"$ACTION_DIR/action.yml\""
    [[ "$status" -eq 0 ]]
}

@test "container: upload-artifact path uses meta_dir output, not get_sbom output" {
    # `meta_dir` always runs (no upstream dependency on the build); `get_sbom`
    # depends on a successful build. The upload must reference meta_dir or
    # `if: always()` could resolve to an empty path on failure.
    run grep -E 'path:[[:space:]]*\$\{\{[[:space:]]*steps\.meta_dir\.outputs\.metadata-dir' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    run grep -E 'path:[[:space:]]*\$\{\{[[:space:]]*steps\.get_sbom\.outputs\.metadata-dir' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 1 ]]
}

@test "container: composite metadata-dir output sources from meta_dir step" {
    # The composite's metadata-dir output must reference meta_dir (always
    # runs), not get_sbom (depends on build success).
    run grep -E '^[[:space:]]+value:[[:space:]]*\$\{\{[[:space:]]*steps\.meta_dir\.outputs\.metadata-dir' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow exposes metadata-artifact-name output" {
    run grep 'metadata-artifact-name:' "$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow has prep job calling the prep action" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^  prep:' "$wf"
    [[ "$status" -eq 0 ]]
    run grep -E 'TomHennen/wrangle/actions/prep@' "$wf"
    [[ "$status" -eq 0 ]]
}

@test "container: reusable workflow exposes release-events input and should-release output" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^      release-events:' "$wf"
    [[ "$status" -eq 0 ]]
    run grep -E '^      should-release:' "$wf"
    [[ "$status" -eq 0 ]]
}

# --- verify job: registry push + permissions ---
# verify: is the last job; the block runs from `  verify:` to EOF.

@test "container: verify job does NOT request contents: write (caller grants only read)" {
    # The container caller grants contents: read; requesting write here is a
    # startup-failing permission escalation. This is the dispatch-failure fix.
    # Match the permission-block entry (6-space indent), not the explanatory
    # comment that also mentions the phrase.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  verify:/,\$p' \"$wf\" | grep -E '^      contents:[[:space:]]*write'"
    [[ "$status" -ne 0 ]]
}

@test "container: verify job requests packages: write for the registry push" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  verify:/,\$p' \"$wf\" | grep -E '^      packages:[[:space:]]*write'"
    [[ "$status" -eq 0 ]]
}

@test "container: verify job pushes the VSA as its own by-digest OCI referrer (oci-target + attach-to-release false)" {
    # Container does NOT attach to a release (it produces none); the combined
    # bundle is the workflow artifact, and the VSA is pushed by image digest as
    # its own referrer (oci-target), so the verify step turns the release attach
    # off. The push itself is fail-closed in run_verify.sh.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  verify:/,\$p' \"$wf\" | grep -E 'oci-target:'"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  verify:/,\$p' \"$wf\" | grep -E 'attach-to-release:[[:space:]]*\"false\"'"
    [[ "$status" -eq 0 ]]
}

@test "container: verify job installs cosign for the push (single pin across the workflow)" {
    # The push runs cosign attach; the installer must be SHA-pinned, and
    # any other cosign-installer reference must share the same pin so the
    # versions never drift.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  verify:/,\$p' \"$wf\" | grep -E 'sigstore/cosign-installer@[0-9a-f]{40}'"
    [[ "$status" -eq 0 ]]
    local distinct_pins
    distinct_pins="$(grep -oE 'sigstore/cosign-installer@[0-9a-f]{40}' "$wf" | sort -u | wc -l)"
    # Exactly one distinct pin across the whole workflow.
    [[ "$distinct_pins" -eq 1 ]]
}

@test "container: verify job authenticates to ghcr before the push" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  verify:/,\$p' \"$wf\" | grep -E 'docker/login-action@[0-9a-f]{40}'"
    [[ "$status" -eq 0 ]]
}

# --- Workflow-command-injection guard (#225 / SLSA_L3_AUDIT.md Finding 3) ---

@test "container: stop-commands guard helper exists and is executable" {
    [[ -x "$REPO_ROOT/lib/stop_commands_guard.sh" ]]
}

@test "container: docker build is bracketed by the stop-commands guard" {
    # docker/build-push-action streams BuildKit's per-RUN-layer output to
    # the step log; a malicious Dockerfile could otherwise inject a
    # `::add-mask::` / `::set-output::` workflow command via stdout. The
    # guard's begin/end subcommands bracket the build step.
    # See docs/SLSA_L3_AUDIT.md Finding 3.
    run grep -E 'stop_commands_guard\.sh" begin' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    run grep -E 'stop_commands_guard\.sh" end' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
    # The begin step must carry id: stopcmd — the end step reads the token
    # from steps.stopcmd.outputs to close the same guard.
    run bash -c "sed -n '/name: Suspend workflow commands/,/run:/p' \"$ACTION_DIR/action.yml\" | grep -F 'id: stopcmd'"
    [[ "$status" -eq 0 ]]
}

@test "container: stop-commands begin precedes the build and end follows it" {
    # begin → docker build → end ordering is what makes the guard cover
    # the build. A reordering would silently leave the build unguarded.
    run bash -c "awk '/stop_commands_guard.sh\" begin/{b=NR} /uses: docker\\/build-push-action/{d=NR} /stop_commands_guard.sh\" end/{e=NR} END{exit !(b && d && e && b<d && d<e)}' \"$ACTION_DIR/action.yml\""
    [[ "$status" -eq 0 ]]
}

@test "container: the stop-commands re-enable step runs with if: always()" {
    # stop-commands is job-scoped in the runner: a failed docker build
    # that left commands suspended would disable ::add-mask:: secret
    # redaction for every later step. The re-enable MUST be unconditional.
    run bash -c "sed -n '/name: Re-enable workflow commands/,/run:/p' \"$ACTION_DIR/action.yml\" | grep -F 'if: always()'"
    [[ "$status" -eq 0 ]]
}

@test "container: re-enable step passes the token through env, not run interpolation" {
    # The token is a step output; interpolating it directly into a run:
    # block would trip zizmor's template-injection audit. It must flow
    # through env: per CLAUDE.md's expression-injection rule.
    run grep -F 'STOP_COMMANDS_TOKEN: ${{ steps.stopcmd.outputs.stop-commands-token }}' "$ACTION_DIR/action.yml"
    [[ "$status" -eq 0 ]]
}

# --- attest-build-provenance (wrangle builder identity, #316) ---

@test "container: workflow has attest job pushing GitHub attest-build-provenance to the registry" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^  attest:' "$wf"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$wf\" | grep 'actions/attest-build-provenance@'"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$wf\" | grep -E 'push-to-registry:[[:space:]]*true'"
    [[ "$status" -eq 0 ]]
}

@test "container: attest job is gated on should-release" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$wf\" | grep -E 'if:.*should-release'"
    [[ "$status" -eq 0 ]]
}

@test "container: attest job no longer references the verify_attestation action" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$wf\" | grep 'TomHennen/wrangle/actions/verify_attestation@'"
    [[ "$status" -ne 0 ]]
}

@test "container: attest and verify jobs are gated off when attestation is disabled" {
    # Unattested mode skips signing entirely; the image, pushed mid-composite in
    # build, stays live. Otherwise a private repo's release would still attempt
    # to sign and leak to the public log.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$wf\" | grep -F \"inputs.attestation != 'disabled'\""
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  verify:/,\$p' \"$wf\" | grep -F \"inputs.attestation != 'disabled'\""
    [[ "$status" -eq 0 ]]
}

@test "container: has NO publish-unattested job — the pushed image is the released artifact" {
    # Unlike the dist-based build types, container has no dist to upload and no
    # GitHub release to create: build already pushed the image. Disabled mode is
    # simply attest+verify skipped, so a dist-style publish job would be wrong.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^  publish-unattested:' "$wf"
    [[ "$status" -ne 0 ]]
}

@test "container: build stages the metadata pre transient only on an attested release" {
    # The verify job folds its bundle into the final metadata and owns the final
    # upload. With verify skipped (non-release OR attestation: disabled), build's
    # sbom + scan/ IS the final metadata artifact, so it must not be left as a
    # 1-day pre transient that no verify job ever promotes.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "grep -F \"metadata-pre-artifact-name\" \"$wf\" | grep -F \"inputs.attestation != 'disabled'\""
    [[ "$status" -eq 0 ]]
    # The retention-days ternary must carry the same gate: gating the name but
    # leaving retention at should-release would 1-day-expire the final artifact.
    run bash -c "grep -F \"retention-days:\" \"$wf\" | grep -F \"inputs.attestation != 'disabled'\""
    [[ "$status" -eq 0 ]]
}

@test "container: workflow has NO provenance job and NO slsa generator/verifier ref" {
    # attest-build-provenance is the sole provenance; the verify job is the sole
    # verify. Patterns are narrow on purpose: a bare `slsa-verifier` would
    # false-fail on the workflow comment that names the old verifier job in prose.
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run grep -E '^  provenance:' "$wf"
    [[ "$status" -ne 0 ]]
    run grep 'slsa-github-generator' "$wf"
    [[ "$status" -ne 0 ]]
    run grep 'slsa-verifier/actions' "$wf"
    [[ "$status" -ne 0 ]]
}

@test "container: verify job threads the policy input, which defaults to the per-eco default tier" {
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  verify:/,\$p' \"$wf\" | grep -F 'policy: \${{ inputs.policy }}'"
    [[ "$status" -eq 0 ]]
    run bash -c "grep -F 'default: policies/wrangle-default-container-v1.hjson' \"$wf\""
    [[ "$status" -eq 0 ]]
}

@test "container: verify job collects provenance via the oci referrer collector" {
    # The attest job pushed the bundle to the registry as an OCI referrer;
    # the verify job reads it back via the oci: collector (not a jsonl bundle).
    local wf="$REPO_ROOT/.github/workflows/build_and_publish_container.yml"
    run bash -c "sed -n '/^  verify:/,\$p' \"$wf\" | grep -E 'collector: oci:'"
    [[ "$status" -eq 0 ]]
}
