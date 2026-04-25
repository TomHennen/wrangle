#!/usr/bin/env bats

# Structural tests for the Python build action and reusable workflow.
#
# Many tests below are simple greps. They verify that the action's wiring
# and supply-chain rules (no curl|sh, no /usr/local/bin, SHA-pinned actions,
# SBOM upload) are still in place. They do not invoke the action end-to-end —
# that's covered by the integration test in the wrangle-test companion repo.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    WORKFLOW="$REPO_ROOT/.github/workflows/build_and_publish_python.yml"
    EXAMPLE="$REPO_ROOT/gh_workflow_examples/build_python.yml"
}

# --- Composite action structural tests ---

@test "python: action.yml exists" {
    [[ -f "$ACTION" ]]
}

@test "python: validate_inputs.sh exists and is executable" {
    [[ -x "$ACTION_DIR/validate_inputs.sh" ]]
}

@test "python: install_deps.sh exists and is executable" {
    [[ -x "$ACTION_DIR/install_deps.sh" ]]
}

@test "python: run_tests.sh exists and is executable" {
    [[ -x "$ACTION_DIR/run_tests.sh" ]]
}

@test "python: action.yml delegates input validation to validate_inputs.sh" {
    run grep 'validate_inputs.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: action.yml delegates dependency install to install_deps.sh" {
    run grep 'install_deps.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: action.yml delegates test run to run_tests.sh" {
    run grep 'run_tests.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: validate_inputs.sh checks for pyproject.toml" {
    run grep 'pyproject.toml' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
}

@test "python: install_deps.sh supports both uv and pip paths" {
    run grep -E 'uv sync|uv build' "$ACTION_DIR/install_deps.sh"
    [[ "$status" -eq 0 ]]
    run grep 'pip install' "$ACTION_DIR/install_deps.sh"
    [[ "$status" -eq 0 ]]
}

@test "python: run_tests.sh runs pytest" {
    run grep -E 'uv run pytest|python -m pytest' "$ACTION_DIR/run_tests.sh"
    [[ "$status" -eq 0 ]]
}

@test "python: action.yml detects uv.lock for tooling choice" {
    run grep 'uv.lock' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: action.yml supports standard PEP 517 build path" {
    run grep 'python -m build' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: action.yml supports uv build path" {
    run grep 'uv build' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: action.yml computes artifact hashes for SLSA" {
    run grep -E 'sha256sum|base64' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: action.yml generates SBOM" {
    run grep -E 'spdx-json|sbom' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: passes inputs through env not interpolation" {
    # No ${{ inputs.* }} in run: blocks (action_path is allowed).
    run grep -P 'run:.*\$\{\{.*inputs\.' "$ACTION"
    [[ "$status" -eq 1 ]]
}

@test "python: validate_inputs.sh disables globbing via lib/validate_path.sh" {
    # External input flows through validate_path.sh; CLAUDE.md requires set -f there.
    run grep '^set -f' "$REPO_ROOT/lib/validate_path.sh"
    [[ "$status" -eq 0 ]]
}

# --- Reusable workflow structural tests ---

@test "python: workflow exists" {
    [[ -f "$WORKFLOW" ]]
}

@test "python: workflow has build job with minimal permissions" {
    run grep -A2 'build:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    # Build job should only have contents: read
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep 'id-token'"
    [[ "$status" -eq 1 ]]
}

@test "python: workflow has no publish job (Trusted Publishing OIDC constraint)" {
    # Publish must be in the adopter's workflow because PyPI rejects OIDC
    # tokens whose workflow_ref points at a reusable workflow.
    run grep '^  publish:' "$WORKFLOW"
    [[ "$status" -eq 1 ]]
}

@test "python: workflow has provenance job calling slsa-github-generator" {
    run grep '^  provenance:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'slsa-github-generator' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: provenance job is gated on non-PR events" {
    # On PRs, publish doesn't run, so provenance is wasted compute.
    run bash -c "sed -n '/^  provenance:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E \"if:.*startsWith.*pull_\""
    [[ "$status" -eq 0 ]]
}

@test "python: workflow exports hashes output" {
    run grep 'hashes:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: workflow documents PyPI reusable workflow limitation" {
    run grep -E 'warehouse/issues/11096|Trusted Publishing.*reusable' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: workflow pins actions to SHAs except SLSA generator" {
    # The SLSA generator MUST be referenced by tag (#147). Everything else SHA-pins.
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v 'slsa-github-generator' | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]
}

@test "python: workflow uploads SBOM/metadata, not just dist" {
    run grep -E 'metadata-dir|python-metadata' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: workflow namespaces artifacts by shortname" {
    run grep 'python-dist-' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: action installs syft via tools/syft (not curl | sh)" {
    run grep -E 'curl[^|]*\| *sh|/usr/local/bin' "$ACTION"
    [[ "$status" -ne 0 ]]
    run grep 'tools/syft/install.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: action installs cosign before syft (signature verification)" {
    run bash -c "awk '/sigstore\\/cosign-installer/{c=NR} /tools\\/syft\\/install.sh/{s=NR} END{exit !(c && s && c<s)}' \"$ACTION\""
    [[ "$status" -eq 0 ]]
}

@test "python: hashes step strips ./ prefix for slsa-verifier" {
    # sha256sum ./* yields ./<file>; sha256sum -- * (after cd) yields <file>.
    run grep -E 'cd .*dist.* && sha256sum' "$ACTION"
    [[ "$status" -eq 0 ]]
}

# --- Example workflow tests ---

@test "python: example workflow downloads provenance artifact" {
    run grep 'provenance-artifact-name' "$EXAMPLE"
    [[ "$status" -eq 0 ]]
}

@test "python: example workflow installs and runs slsa-verifier before publish" {
    run grep 'slsa-verifier/actions/installer' "$EXAMPLE"
    [[ "$status" -eq 0 ]]
    # verify-artifact must appear before pypi-publish
    run bash -c "awk '/slsa-verifier verify-artifact/{v=NR} /pypa\\/gh-action-pypi-publish/{p=NR} END{exit !(v && p && v<p)}' \"$EXAMPLE\""
    [[ "$status" -eq 0 ]]
}

@test "python: example workflow does NOT call SLSA generator (moved to reusable)" {
    # Provenance generation now lives in wrangle's reusable workflow, not the example.
    run grep 'slsa-github-generator' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
}
