#!/usr/bin/env bats

# Tests for the Go build action and reusable workflow.
#
# Three test layers, in increasing order of cost:
#   1. Behavioral tests that invoke validate_inputs.sh end-to-end against
#      fixture project directories.
#   2. Structural greps over action.yml, the reusable workflow, and the
#      example workflow — supply-chain guard rails (SHA-pinned actions,
#      inputs through env:, no inline shell injection, etc.).
#   3. build_go.sh is intentionally NOT exhaustively tested here: its
#      logic invokes the real Go toolchain (`gofmt`, `go vet`, `go test`,
#      `go install`, `govulncheck`), which is faithfully exercised by
#      the integration test in the wrangle-test companion repo. The
#      cost of shimming all those binaries with realistic enough
#      behavior to test the orchestration is high; the integration test
#      catches the orchestration regressions for free.

setup_file() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    export ACTION_DIR
}

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    WORKFLOW="$REPO_ROOT/.github/workflows/build_and_publish_go.yml"
    EXAMPLE="$REPO_ROOT/gh_workflow_examples/build_go.yml"
}

# --- Composite action structural tests ---

@test "go: action.yml exists" {
    [[ -f "$ACTION" ]]
}

@test "go: validate_inputs.sh exists and is executable" {
    [[ -x "$ACTION_DIR/validate_inputs.sh" ]]
}

@test "go: build_go.sh exists and is executable" {
    [[ -x "$ACTION_DIR/build_go.sh" ]]
}

@test "go: action.yml delegates input validation to validate_inputs.sh" {
    run grep 'validate_inputs.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "go: action.yml delegates pre-build checks to build_go.sh" {
    run grep 'build_go.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "go: action.yml uses actions/setup-go (SHA-pinned)" {
    run grep -E 'actions/setup-go@[0-9a-f]{40}' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "go: action.yml uses goreleaser/goreleaser-action (SHA-pinned)" {
    run grep -E 'goreleaser/goreleaser-action@[0-9a-f]{40}' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "go: goreleaser binary version is pinned literally (no '~>', no '@latest')" {
    # The goreleaser-action's `version:` input controls which goreleaser
    # binary the action downloads at runtime. wrangle's supply-chain
    # discipline (CLAUDE.md "No auto-merge of dependency updates")
    # forbids unpinned upstream versions: a new goreleaser release MUST
    # be deliberately adopted via a wrangle PR, not amplified by every
    # build the moment it ships. Pattern `~> vN` is the goreleaser-action
    # range syntax; `latest` is also unpinned. Both must be rejected.
    run grep -E "^[[:space:]]*version:[[:space:]]*['\"]?(~>|latest)" "$ACTION"
    [[ "$status" -ne 0 ]]
    # Pinned version must look like X.Y.Z (no leading v, per the
    # goreleaser-action input contract).
    run grep -E "^[[:space:]]*version:[[:space:]]*['\"][0-9]+\\.[0-9]+\\.[0-9]+['\"]" "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "go: setup-go cache is gated by the cache input (release-vs-PR asymmetry)" {
    # Release builds disable the Go module + build caches because Go's
    # build cache trusts pre-derived compiled output keyed by source
    # fingerprint — the same shape as the uv-cache L3 gap. The reusable
    # workflow flips the cache input on should-release; the composite
    # MUST honor it. A regression to a literal `cache: true` would
    # re-enable caching for release builds and break L3 isolation.
    run grep -E "cache: \\\$\\{\\{ inputs\\.cache != 'disabled' \\}\\}" "$ACTION"
    [[ "$status" -eq 0 ]]
    # The action must NOT hard-code `cache: true` anywhere.
    run grep -E "^[[:space:]]*cache:[[:space:]]*['\"]?true['\"]?[[:space:]]*\$" "$ACTION"
    [[ "$status" -ne 0 ]]
}

@test "go: goreleaser ALWAYS runs with --skip=publish (verify-before-publish invariant)" {
    # Goreleaser must never publish inline — that would let a bad
    # artifact reach the GitHub Release before verify runs. The
    # reusable workflow's publish job owns release upload, gated on
    # verify success.
    run bash -c "grep -E 'args:.*release' '$ACTION' | grep -v 'skip=publish'"
    [[ "$status" -ne 0 ]]
}

@test "go: action.yml computes artifact hashes from goreleaser's checksums.txt" {
    # Goreleaser writes dist/checksums.txt in `<sha256>  <filename>`
    # format — already sha256sum-style. base64-encode that file
    # directly rather than re-hashing the binaries.
    run grep -E 'base64.*checksums\.txt|checksums\.txt.*base64' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "go: action.yml generates SBOM via syft (SPDX)" {
    run grep -E 'syft.*-o spdx-json' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "go: action installs cosign before syft (signature verification)" {
    # syft install via tools/syft/install.sh uses Cosign keyless verify;
    # cosign-installer must run before the syft install step.
    run bash -c "awk '/sigstore\\/cosign-installer/{c=NR} /tools\\/syft\\/install.sh/{s=NR} END{exit !(c && s && c<s)}' \"$ACTION\""
    [[ "$status" -eq 0 ]]
}

@test "go: action installs syft via tools/syft (not curl | sh)" {
    run grep -E 'curl[^|]*\| *sh|/usr/local/bin' "$ACTION"
    [[ "$status" -ne 0 ]]
    run grep 'tools/syft/install.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "go: action.yml exposes cache input (default enabled)" {
    run grep -E '^  cache:' "$ACTION"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  cache:/,/^  [a-z]/p' \"$ACTION\" | grep -E 'default:.*\"enabled\"'"
    [[ "$status" -eq 0 ]]
}

@test "go: action.yml exposes govulncheck-version input (pinned)" {
    run grep -E '^  govulncheck-version:' "$ACTION"
    [[ "$status" -eq 0 ]]
    # Default must be a pinned version (vX.Y.Z), not unpinned (latest, main).
    run bash -c "sed -n '/^  govulncheck-version:/,/^  [a-z]/p' \"$ACTION\" | grep -E 'default:.*\"v[0-9]+\\.[0-9]+\\.[0-9]+\"'"
    [[ "$status" -eq 0 ]]
}

@test "go: passes inputs through env not interpolation" {
    # Walks both single-line `run: <cmd>` declarations and block-form
    # `run: |` / `run: >` bodies, and fails if ${{ inputs.* }} appears
    # inside either. github.action_path is allowed (it's not user input).
    run awk '
        BEGIN { in_run = 0; run_col = -1; bad = 0 }
        /^[[:space:]]*run:[[:space:]]+[^|>]/ && /\$\{\{[[:space:]]*inputs\./ {
            printf "FAIL inline run, line %d: %s\n", NR, $0
            bad = 1
        }
        /^[[:space:]]*run:[[:space:]]*([|>]|$)/ {
            match($0, /^ */); run_col = RLENGTH
            in_run = 1; next
        }
        in_run {
            if ($0 !~ /[^[:space:]]/) next
            match($0, /^ */); col = RLENGTH
            if (col <= run_col) { in_run = 0 }
            else if (/\$\{\{[[:space:]]*inputs\./) {
                printf "FAIL run-block body, line %d: %s\n", NR, $0
                bad = 1
            }
        }
        END { exit bad }
    ' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "go: validate_inputs.sh disables globbing via lib/validate_path.sh" {
    # External input flows through validate_path.sh; CLAUDE.md requires set -f there.
    run grep '^set -f' "$REPO_ROOT/lib/validate_path.sh"
    [[ "$status" -eq 0 ]]
}

# --- validate_inputs.sh behavioral tests ---

write_gomod() {
    local dir="$1"
    mkdir -p "$dir"
    printf 'module example.com/x\n\ngo 1.22\n' > "$dir/go.mod"
}

write_goreleaser() {
    local dir="$1"
    printf 'version: 2\nbuilds:\n  - flags: [-trimpath]\n' > "$dir/.goreleaser.yml"
}

@test "go: validate_inputs.sh accepts a project with go.mod + .goreleaser.yml" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_gomod "$proj"
    write_goreleaser "$proj"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -eq 0 ]]
}

@test "go: validate_inputs.sh accepts .goreleaser.yaml (alternate extension)" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_gomod "$proj"
    printf 'version: 2\n' > "$proj/.goreleaser.yaml"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -eq 0 ]]
}

@test "go: validate_inputs.sh rejects missing go.mod" {
    local proj="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$proj"
    write_goreleaser "$proj"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no go.mod found"* ]]
}

@test "go: validate_inputs.sh rejects missing .goreleaser.yml with a BYO hint" {
    # Wrangle does not ship a starter goreleaser config; adopters must
    # supply their own. The error message must point at the customization
    # docs, not silently fail later inside goreleaser.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_gomod "$proj"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no .goreleaser.yml"* ]]
    [[ "$output" == *"goreleaser.com/customization"* ]]
}

@test "go: validate_inputs.sh rejects absolute path via lib/validate_path.sh" {
    run "$ACTION_DIR/validate_inputs.sh" "/abs/path"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"path must be relative"* ]]
}

@test "go: validate_inputs.sh rejects parent-directory traversal" {
    run "$ACTION_DIR/validate_inputs.sh" "../escape"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"path traversal not allowed"* ]]
}

@test "go: validate_inputs.sh usage error with no args" {
    run "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

# --- build_go.sh structural tests ---
#
# The orchestration is verified via the wrangle-test companion integration
# test (real goreleaser + real govulncheck against a real fixture). These
# greps capture the load-bearing invariants without booting a Go toolchain.

@test "go: build_go.sh runs gofmt -l (formatting enforced; build won't catch it otherwise)" {
    # `go build` does NOT enforce gofmt. Without an explicit check, code
    # with broken formatting will compile and release through wrangle
    # unchallenged. This is a stop-gap until #194 lands.
    run grep -E 'gofmt -l' "$ACTION_DIR/build_go.sh"
    [[ "$status" -eq 0 ]]
}

@test "go: build_go.sh runs go vet" {
    run grep -E 'go vet ./\.\.\.' "$ACTION_DIR/build_go.sh"
    [[ "$status" -eq 0 ]]
}

@test "go: build_go.sh runs go test with -race" {
    # -race catches data races that would otherwise ship in the released
    # binary. Mandatory.
    run grep -E 'go test -race ./\.\.\.' "$ACTION_DIR/build_go.sh"
    [[ "$status" -eq 0 ]]
}

@test "go: build_go.sh installs govulncheck via go install with a pinned version (no @latest)" {
    # @latest is unpinned and amplifies upstream — supply-chain hygiene
    # forbids it. The version must be passed in as an argument so the
    # action's input controls the pin.
    run grep -E 'go install .*govulncheck@\$\{?GOVULNCHECK_VERSION' "$ACTION_DIR/build_go.sh"
    [[ "$status" -eq 0 ]]
    run grep -E 'govulncheck@latest|govulncheck@main' "$ACTION_DIR/build_go.sh"
    [[ "$status" -ne 0 ]]
}

@test "go: build_go.sh writes govulncheck output to metadata dir (not stdout-only)" {
    # govulncheck JSON output goes to the metadata artifact so adopters
    # can see what was scanned: govulncheck.json file referenced AND
    # govulncheck called in -json mode.
    run grep -F 'govulncheck.json' "$ACTION_DIR/build_go.sh"
    [[ "$status" -eq 0 ]]
    run grep -E 'govulncheck"? -json' "$ACTION_DIR/build_go.sh"
    [[ "$status" -eq 0 ]]
}

# --- Reusable workflow structural tests ---

@test "go: workflow exists" {
    [[ -f "$WORKFLOW" ]]
}

@test "go: workflow has build job with minimal permissions (contents: read only)" {
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E '^[[:space:]]*id-token:'"
    [[ "$status" -ne 0 ]]
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E 'contents: read'"
    [[ "$status" -eq 0 ]]
}

@test "go: workflow has provenance job calling slsa-github-generator" {
    run grep '^  provenance:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'slsa-github-generator' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "go: workflow has publish job (Go differs from python/npm — no caller-bound publish constraint)" {
    # Go's publish target is GitHub Releases, which has no caller-bound
    # OIDC publish constraint. Wrangle owns the publish to preserve
    # verify-before-publish (the SLSA generator's upload-assets would
    # publish before verify runs).
    run grep '^  publish:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "go: publish job is gated on tag-push AND should-release AND needs verify" {
    run bash -c "sed -n '/^  publish:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E \"if:.*should-release.*startsWith.*refs/tags|if:.*startsWith.*refs/tags.*should-release\""
    [[ "$status" -eq 0 ]]
    # Publish depends on verify so a failed verify blocks publish via
    # standard needs: propagation.
    run bash -c "sed -n '/^  publish:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E 'needs:.*verify'"
    [[ "$status" -eq 0 ]]
}

@test "go: provenance job has upload-assets: false (publish job owns the release upload)" {
    # If upload-assets were true, the SLSA generator would attach
    # provenance to a release BEFORE verify runs — defeating
    # verify-before-publish. The wrangle publish job uploads after.
    run bash -c "sed -n '/^  provenance:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E 'upload-assets:[[:space:]]*false'"
    [[ "$status" -eq 0 ]]
}

@test "go: provenance job is gated on should-release" {
    run bash -c "sed -n '/^  provenance:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E 'if:.*should-release'"
    [[ "$status" -eq 0 ]]
}

@test "go: workflow has gate job calling release_gate" {
    run grep -E '^  gate:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep -E 'TomHennen/wrangle/actions/release_gate' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "go: workflow exposes release-events input" {
    run grep -E '^      release-events:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "go: workflow exports hashes, provenance-artifact-name, metadata-artifact-name outputs" {
    run grep 'hashes:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'provenance-artifact-name:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'metadata-artifact-name:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "go: workflow pins actions to SHAs except SLSA generator" {
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v 'slsa-github-generator' | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]
}

@test "go: workflow uploads SBOM/metadata, not just dist" {
    run grep -E 'metadata-dir|go-metadata' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "go: workflow namespaces artifacts by shortname" {
    run grep 'go-dist-' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "go: reusable workflow has verify job calling slsa-verifier" {
    run grep -E '^  verify:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'slsa-verifier/actions/installer' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'slsa-verifier verify-artifact' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "go: verify job is gated on should-release AND verify-provenance" {
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E \"if:.*should-release.*verify-provenance\""
    [[ "$status" -eq 0 ]]
}

@test "go: workflow exposes verify-provenance input (default true)" {
    run grep -E '^      verify-provenance:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^      verify-provenance:/,/^      [a-z]/p' \"$WORKFLOW\" | grep -E 'default:[[:space:]]*true'"
    [[ "$status" -eq 0 ]]
}

@test "go: provenance job passes namespaced provenance-name to SLSA generator" {
    run bash -c "sed -n '/^  provenance:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E 'provenance-name:.*shortname'"
    [[ "$status" -eq 0 ]]
}

@test "go: build job exposes shortname output" {
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E '^[[:space:]]*shortname:'"
    [[ "$status" -eq 0 ]]
}

@test "go: verify job depends on provenance and downloads its artifact" {
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E 'needs:.*provenance'"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$WORKFLOW\" | grep 'needs.provenance.outputs.provenance-name'"
    [[ "$status" -eq 0 ]]
}

@test "go: workflow disables cache on release builds (L3 isolation)" {
    # The build job passes cache: disabled when should-release is true.
    # Re-enabling cache on release builds would expose the build to
    # cross-build cache poisoning (Go's build cache trusts pre-derived
    # compiled output — same shape as the uv-cache L3 gap).
    run bash -c "grep -E \"cache:.*should-release == 'true'.*disabled\" \"$WORKFLOW\""
    [[ "$status" -eq 0 ]]
}

@test "go: checkout fetches tags (goreleaser requires tag visibility)" {
    # Goreleaser reads the current tag and recent commit history to
    # derive the version. The default `actions/checkout` is a shallow
    # fetch without tags, which makes goreleaser misdetect the version.
    run grep -E 'fetch-tags: true' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

# --- Example workflow tests ---

@test "go: example workflow exists" {
    [[ -f "$EXAMPLE" ]]
}

@test "go: example workflow does NOT install slsa-verifier (verification owned by reusable workflow)" {
    run grep 'slsa-verifier/actions/installer' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
    run grep 'slsa-verifier verify-artifact' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
}

@test "go: example workflow does NOT call SLSA generator (moved to reusable)" {
    run grep 'slsa-github-generator' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
}

@test "go: example workflow does NOT have a publish job (wrangle owns publish for Go)" {
    # Unlike python/npm, Go's publish is owned by wrangle. The adopter
    # workflow is one job: build (which calls the reusable workflow).
    run grep -E '^  publish:' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
}

@test "go: example workflow grants contents: write to build job" {
    # contents: write is required because the reusable workflow's
    # publish job uploads to GitHub Releases AND the SLSA generator's
    # upload-assets job declares it at startup.
    run grep -E 'contents: write' "$EXAMPLE"
    [[ "$status" -eq 0 ]]
}

# --- Workflow-command-injection guard (#225 / SLSA_L3_AUDIT.md Finding 3) ---

@test "go: stop-commands guard helper exists and is executable" {
    [[ -x "$REPO_ROOT/lib/stop_commands_guard.sh" ]]
}

@test "go: build_go.sh runs under the stop-commands guard (test/govulncheck stdout could carry workflow commands)" {
    # build_go.sh runs go test, govulncheck, etc., which execute
    # arbitrary project code. The ::stop-commands:: guard neutralizes
    # workflow-command injection via their stdout. See
    # docs/SLSA_L3_AUDIT.md Finding 3.
    run grep -E 'lib/stop_commands_guard\.sh" run' "$ACTION"
    [[ "$status" -eq 0 ]]
    # The guarded command (on the line after `... run`) must be build_go.sh.
    run bash -c "grep -A1 'stop_commands_guard.sh\" run' \"$ACTION\" | grep -F build_go.sh"
    [[ "$status" -eq 0 ]]
}

@test "go: goreleaser-action is wrapped by stop-commands guard begin/end (it can't be wrapped inline)" {
    # goreleaser-action is a `uses:` step; it can't be wrapped by the
    # `stop_commands_guard.sh run` form. The action.yml uses begin/end:
    # one step emits ::stop-commands::<token>, the goreleaser step runs,
    # a later step emits ::<token>:: to re-enable. The end step MUST be
    # marked `if: always()` so a failed goreleaser doesn't leave commands
    # suspended for the rest of the job.
    run grep -E 'stop_commands_guard\.sh" begin' "$ACTION"
    [[ "$status" -eq 0 ]]
    run grep -E 'stop_commands_guard\.sh" end' "$ACTION"
    [[ "$status" -eq 0 ]]
    # The end step must be if: always() — otherwise a goreleaser failure
    # leaves stop-commands in effect, silently disabling ::add-mask::
    # for the rest of the job.
    run bash -c "grep -A2 'Resume workflow commands' '$ACTION' | grep -E 'if: always'"
    [[ "$status" -eq 0 ]]
}
