#!/usr/bin/env bats

# Structural tests for the npm build action and reusable workflow.
#
# Many tests below are simple greps. They verify that the action's wiring
# and supply-chain rules (no curl|sh, no /usr/local/bin, SHA-pinned actions,
# SBOM upload) are still in place. They do not invoke the action end-to-end —
# that's covered by the integration test in the wrangle-test companion repo.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    WORKFLOW="$REPO_ROOT/.github/workflows/build_and_publish_npm.yml"
    EXAMPLE="$REPO_ROOT/gh_workflow_examples/build_npm.yml"
}

# --- Composite action structural tests ---

@test "npm: action.yml exists" {
    [[ -f "$ACTION" ]]
}

@test "npm: validate_inputs.sh exists and is executable" {
    [[ -x "$ACTION_DIR/validate_inputs.sh" ]]
}

@test "npm: build_and_pack.sh exists and is executable" {
    [[ -x "$ACTION_DIR/build_and_pack.sh" ]]
}

@test "npm: action.yml delegates input validation to validate_inputs.sh" {
    run grep 'validate_inputs.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: action.yml delegates build/pack to build_and_pack.sh" {
    run grep 'build_and_pack.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh checks for package.json" {
    run grep 'package.json' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh requires a lockfile" {
    run grep 'package-lock.json' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh rejects pnpm and yarn lockfiles in v0.1" {
    run grep 'pnpm-lock.yaml' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
    run grep 'yarn.lock' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: build_and_pack.sh runs npm ci (lockfile-faithful)" {
    run grep -E 'npm ci' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: build_and_pack.sh runs npm pack" {
    run grep -E 'npm pack' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: build_and_pack.sh detects scripts.build via jq, not by catching missing-script errors" {
    run grep -E 'jq.*scripts.*build' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: build_and_pack.sh skips npm's default no-op test script" {
    run grep -F 'no test specified' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: build_and_pack.sh writes tarball to dist/" {
    run grep -E 'pack-destination dist|mkdir -p dist' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: action.yml uses actions/setup-node" {
    run grep 'actions/setup-node@' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: action.yml sets a fallback Node version when no version source is present" {
    # Without this, setup-node fails with a confusing "no version found"
    # error for projects that pin neither .nvmrc nor engines.node.
    run grep -E 'WRANGLE_DEFAULT_NODE' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: build step asserts exactly one tarball in dist/ (not tail-n1)" {
    # Channel-free output: derives the tarball name from a glob over
    # dist/*.tgz and asserts the count is exactly 1 — catches surprise
    # multi-build scenarios (e.g., a future workspace change) explicitly,
    # instead of non-deterministically picking via `tail -n1`.
    run grep -E 'expected exactly 1 tarball' "$ACTION"
    [[ "$status" -eq 0 ]]
    # And verify we are not relying on tail -n1 for the tarball capture.
    run grep -E 'tarball=.*tail' "$ACTION"
    [[ "$status" -ne 0 ]]
}

@test "npm: action.yml computes artifact hashes for SLSA" {
    run grep -E 'sha256sum|base64' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: action.yml generates SBOM via syft (SPDX)" {
    # Switched from `npm sbom --sbom-format=spdx` to syft because npm
    # sbom's SPDX/CycloneDX conformance was publicly criticized; syft is
    # OWASP-known-conformant and already in wrangle's tool inventory.
    run grep -E 'syft.*-o spdx-json' "$ACTION"
    [[ "$status" -eq 0 ]]
    # Should NOT regress to npm sbom — that path was abandoned.
    run grep -E 'npm sbom' "$ACTION"
    [[ "$status" -ne 0 ]]
}

@test "npm: action installs cosign before syft (signature verification)" {
    # syft install via tools/syft/install.sh uses Cosign keyless verify;
    # cosign-installer must run before the syft install step so the
    # cosign binary is on PATH when syft's install script runs.
    run bash -c "awk '/sigstore\\/cosign-installer/{c=NR} /tools\\/syft\\/install.sh/{s=NR} END{exit !(c && s && c<s)}' \"$ACTION\""
    [[ "$status" -eq 0 ]]
}

@test "npm: action installs syft via tools/syft (not curl | sh)" {
    run grep -E 'curl[^|]*\| *sh|/usr/local/bin' "$ACTION"
    [[ "$status" -ne 0 ]]
    run grep 'tools/syft/install.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: action.yml exposes ignore-scripts input (default false)" {
    run grep -E '^  ignore-scripts:' "$ACTION"
    [[ "$status" -eq 0 ]]
    # Default must be false — ecosystem norm is hooks-on, and turning
    # them off would break husky/prebuild-install for typical adopters.
    run bash -c "sed -n '/^  ignore-scripts:/,/^  [a-z]/p' \"$ACTION\" | grep -E 'default:.*\"false\"'"
    [[ "$status" -eq 0 ]]
}

@test "npm: build_and_pack.sh threads ignore-scripts through to npm ci AND npm pack" {
    run grep -E 'ignore_scripts_args' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
    # Must be applied to both `npm ci` and `npm pack`, not just one.
    run bash -c "grep 'npm ci.*ignore_scripts_args' \"$ACTION_DIR/build_and_pack.sh\""
    [[ "$status" -eq 0 ]]
    run bash -c "grep 'npm pack.*ignore_scripts_args' \"$ACTION_DIR/build_and_pack.sh\""
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh rejects package.json with workspaces field" {
    # v0.1 single-package only. A workspaces project would produce N
    # tarballs that wrangle would not attest correctly.
    run grep -E 'workspaces' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: reusable workflow exposes ignore-scripts input that flows to composite" {
    # Workflow declares the input.
    run grep -E '^      ignore-scripts:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    # And forwards `inputs.ignore-scripts` through to the composite.
    # The threading line is the only place this expression appears.
    run grep -E 'ignore-scripts:[[:space:]]*\$\{\{[[:space:]]*inputs\.ignore-scripts' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: passes inputs through env not interpolation" {
    # Walks both single-line `run: <cmd>` declarations and block-form
    # `run: |` / `run: >` bodies, and fails if ${{ inputs.* }} appears
    # inside either. github.action_path is allowed (it's not user input).
    # The earlier line-wise grep this replaces missed multi-line cases.
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

@test "npm: validate_inputs.sh disables globbing via lib/validate_path.sh" {
    # External input flows through validate_path.sh; CLAUDE.md requires set -f there.
    run grep '^set -f' "$REPO_ROOT/lib/validate_path.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: hashes step strips ./ prefix for slsa-verifier" {
    # sha256sum ./* yields ./<file>; sha256sum -- * (after cd) yields <file>.
    run grep -E 'cd .*dist.* && sha256sum' "$ACTION"
    [[ "$status" -eq 0 ]]
}

# --- Reusable workflow structural tests ---

@test "npm: workflow exists" {
    [[ -f "$WORKFLOW" ]]
}

@test "npm: workflow has build job with minimal permissions" {
    run grep -A2 'build:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    # Build job should only have contents: read
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep 'id-token'"
    [[ "$status" -eq 1 ]]
}

@test "npm: workflow has no publish job (Trusted Publishing OIDC constraint)" {
    # Publish must be in the adopter's workflow because npm's Trusted
    # Publishing validates the OIDC token's workflow_ref against the
    # caller's filename, not the reusable workflow's path.
    run grep '^  publish:' "$WORKFLOW"
    [[ "$status" -eq 1 ]]
}

@test "npm: workflow has provenance job calling slsa-github-generator" {
    run grep '^  provenance:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'slsa-github-generator' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: provenance job is gated on release-gate output" {
    run bash -c "sed -n '/^  provenance:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E \"if:.*should-release\""
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow has gate job calling release_gate" {
    run grep -E '^  gate:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep -E 'TomHennen/wrangle/actions/release_gate' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow exposes release-events input" {
    run grep -E '^      release-events:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow exposes should-release output" {
    run grep -E '^      should-release:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow exports hashes, provenance-artifact-name, metadata-artifact-name outputs" {
    run grep 'hashes:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'provenance-artifact-name:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'metadata-artifact-name:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow documents Trusted Publishing reusable workflow limitation" {
    run grep -E 'docs.npmjs.com/trusted-publishers|Trusted Publishing.*workflow_ref' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow pins actions to SHAs except SLSA generator" {
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v 'slsa-github-generator' | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]
}

@test "npm: workflow uploads SBOM/metadata, not just dist" {
    run grep -E 'metadata-dir|npm-metadata' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow namespaces artifacts by shortname" {
    run grep 'npm-dist-' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: reusable workflow has verify job calling slsa-verifier" {
    run grep -E '^  verify:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'slsa-verifier/actions/installer' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'slsa-verifier verify-artifact' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: verify job is gated on should-release AND verify-provenance" {
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E \"if:.*should-release.*verify-provenance\""
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow exposes verify-provenance input (default true)" {
    run grep -E '^      verify-provenance:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^      verify-provenance:/,/^      [a-z]/p' \"$WORKFLOW\" | grep -E 'default:[[:space:]]*true'"
    [[ "$status" -eq 0 ]]
}

@test "npm: provenance job passes namespaced provenance-name to SLSA generator" {
    run bash -c "sed -n '/^  provenance:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E 'provenance-name:.*shortname'"
    [[ "$status" -eq 0 ]]
}

@test "npm: build job exposes shortname output" {
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E '^[[:space:]]*shortname:'"
    [[ "$status" -eq 0 ]]
}

@test "npm: verify job depends on provenance and downloads its artifact" {
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E 'needs:.*provenance'"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$WORKFLOW\" | grep 'needs.provenance.outputs.provenance-name'"
    [[ "$status" -eq 0 ]]
}

# --- Example workflow tests ---

@test "npm: example workflow does NOT install slsa-verifier (verification owned by reusable workflow)" {
    run grep 'slsa-verifier/actions/installer' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
    run grep 'slsa-verifier verify-artifact' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
}

@test "npm: example workflow does NOT call SLSA generator (moved to reusable)" {
    run grep 'slsa-github-generator' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
}

@test "npm: example workflow grants contents: write to build job" {
    # The SLSA generator's upload-assets job declares contents: write; GitHub
    # validates that the caller of wrangle's reusable workflow grants the same
    # at workflow startup.
    run grep -E 'contents: write' "$EXAMPLE"
    [[ "$status" -eq 0 ]]
}

@test "npm: example workflow publishes with --provenance for the L2 in-CLI attestation" {
    run grep -E 'npm publish.*--provenance' "$EXAMPLE"
    [[ "$status" -eq 0 ]]
}

@test "npm: example workflow's publish job grants id-token: write for Trusted Publishing" {
    # Trusted Publishing requires id-token: write on the caller's publish job
    # so the npm CLI can exchange the OIDC token for a publish credential.
    run bash -c "sed -n '/^  publish:/,/^[a-z]/p' \"$EXAMPLE\" | grep 'id-token: write'"
    [[ "$status" -eq 0 ]]
}
