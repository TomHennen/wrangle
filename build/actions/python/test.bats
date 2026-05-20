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
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/python-bats-XXXXXX")"
    GITHUB_OUTPUT="$TMP_DIR/github_output"
    : > "$GITHUB_OUTPUT"
    export GITHUB_OUTPUT
}

teardown() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# Helper: stub `pytest`, `python`, and `uv` on PATH so the build action's
# helper scripts execute without needing real interpreters. Each shim
# records its argv on stdout, which the test then asserts on. The python
# shim implements just enough of `python -m pytest` / `python -m pip ...`
# to keep run_tests.sh and install_deps.sh happy in unit tests.
install_python_shims() {
    mkdir -p "$TMP_DIR/shim"
    cat > "$TMP_DIR/shim/python" <<'SHIM'
#!/bin/bash
printf 'python'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
# Default: succeed. Override per-test via PYTHON_EXIT_<MODULE> env vars
# (e.g., PYTHON_EXIT_PIP=1) to simulate failure paths.
mod=""
if [[ "${1:-}" == "-m" && $# -ge 2 ]]; then
    mod="${2^^}"
    mod="${mod//-/_}"
fi
if [[ -n "$mod" ]]; then
    var="PYTHON_EXIT_${mod}"
    exit "${!var:-0}"
fi
exit 0
SHIM
    cat > "$TMP_DIR/shim/pytest" <<'SHIM'
#!/bin/bash
printf 'pytest'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
exit 0
SHIM
    cat > "$TMP_DIR/shim/uv" <<'SHIM'
#!/bin/bash
printf 'uv'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
exit 0
SHIM
    chmod +x "$TMP_DIR/shim/python" "$TMP_DIR/shim/pytest" "$TMP_DIR/shim/uv"
    PATH="$TMP_DIR/shim:$PATH"
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

@test "python: validate_inputs.sh and validate_path.sh disable globbing with set -f" {
    # Both process external input (validate_inputs.sh now also takes the
    # cache arg); CLAUDE.md requires set -f in scripts that do.
    run grep '^set -f' "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -eq 0 ]]
    run grep '^set -f' "$REPO_ROOT/lib/validate_path.sh"
    [[ "$status" -eq 0 ]]
}

# --- Cache gating (SLSA L3 isolation, #224 / SLSA_L3_AUDIT.md Finding 1) ---

@test "python: validate_inputs.sh accepts cache=enabled and cache=disabled" {
    # validate_path.sh rejects absolute paths, so use a relative project
    # dir: cd into a temp dir and pass the relative subdir name.
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/proj"
    printf '[project]\nname = "x"\nversion = "0"\n' > "$tmp/proj/pyproject.toml"
    cd "$tmp"
    run "$ACTION_DIR/validate_inputs.sh" "proj" "enabled"
    [[ "$status" -eq 0 ]]
    run "$ACTION_DIR/validate_inputs.sh" "proj" "disabled"
    [[ "$status" -eq 0 ]]
    rm -rf "$tmp"
}

@test "python: validate_inputs.sh rejects an invalid cache value" {
    # A typo must fail loudly — silently leaving the uv cache on would
    # downgrade a release build from Build L3 to Build L2.
    run "$ACTION_DIR/validate_inputs.sh" "." "enabledd"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"invalid cache value"* ]]
}

@test "python: validate_inputs.sh rejects a missing cache argument" {
    run "$ACTION_DIR/validate_inputs.sh" "."
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "python: validate_inputs.sh rejects a project with no pyproject.toml" {
    # PEP 621 is required: action.yml uses setup-python's
    # python-version-file pointing at pyproject.toml, so a setup.py-only
    # project would otherwise fail later with a confusing error. Catch it
    # here instead.
    local proj="$TMP_DIR/proj"
    mkdir -p "$proj"
    cd "$TMP_DIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj" "enabled"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no pyproject.toml"* ]]
}

@test "python: action.yml exposes a cache input" {
    run grep -E '^  cache:' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: action.yml passes cache to validate_inputs.sh" {
    run grep -E 'validate_inputs.sh.*INPUT_CACHE' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "python: action.yml gates setup-uv enable-cache on the cache input" {
    # Pin the full expression — operator and operand. A loose
    # 'mentions inputs.cache' regex would still pass if the condition
    # were inverted (== instead of !=), which turns the uv cache ON for
    # release builds: the exact Build L3 downgrade this gating prevents.
    run grep -F "enable-cache: \${{ inputs.cache != 'disabled' }}" "$ACTION"
    [[ "$status" -eq 0 ]]
}

# --- run_tests.sh behavioral tests ---

write_pyproject() {
    # $1: project dir, $2: optional extra TOML appended to the file
    local dir="$1" extra="${2:-}"
    mkdir -p "$dir"
    {
        printf '[project]\nname = "x"\nversion = "0.1.0"\n'
        printf '%s' "$extra"
    } > "$dir/pyproject.toml"
}

@test "python: run_tests.sh runs python -m pytest when tests/ directory exists" {
    install_python_shims
    local proj="$TMP_DIR/proj"
    write_pyproject "$proj"
    mkdir -p "$proj/tests"
    PATH="$PATH" run "$ACTION_DIR/run_tests.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    grep -qE '^python -m pytest$' <<<"$output"
}

@test "python: run_tests.sh accepts a test/ directory (pytest's default singular form)" {
    install_python_shims
    local proj="$TMP_DIR/proj"
    write_pyproject "$proj"
    mkdir -p "$proj/test"
    PATH="$PATH" run "$ACTION_DIR/run_tests.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    grep -qE '^python -m pytest$' <<<"$output"
}

@test "python: run_tests.sh runs pytest when only [tool.pytest] config is in pyproject.toml" {
    # A project that stores tests outside tests/ or test/ should still
    # have its suite run, provided pyproject.toml configures pytest.
    install_python_shims
    local proj="$TMP_DIR/proj"
    write_pyproject "$proj" $'\n[tool.pytest.ini_options]\ntestpaths = ["mytests"]\n'
    PATH="$PATH" run "$ACTION_DIR/run_tests.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    grep -qE '^python -m pytest$' <<<"$output"
}

@test "python: run_tests.sh skips pytest cleanly when no tests/ and no [tool.pytest] config" {
    # No tests is not an error — same behavior as the shell build skipping
    # when no .bats files exist. The message helps adopters discover that
    # tests in a non-standard location need [tool.pytest].
    install_python_shims
    local proj="$TMP_DIR/proj"
    write_pyproject "$proj"
    PATH="$PATH" run "$ACTION_DIR/run_tests.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    ! grep -qE '^pytest' <<<"$output"
    ! grep -qE '^python -m pytest$' <<<"$output"
    [[ "$output" == *"skipping pytest"* ]]
}

@test "python: run_tests.sh uses 'uv run pytest' when use_uv=true" {
    install_python_shims
    local proj="$TMP_DIR/proj"
    write_pyproject "$proj"
    mkdir -p "$proj/tests"
    PATH="$PATH" run "$ACTION_DIR/run_tests.sh" "$proj" "true"
    [[ "$status" -eq 0 ]]
    grep -qE '^uv run pytest$' <<<"$output"
    ! grep -qE '^python -m pytest$' <<<"$output"
}

@test "python: run_tests.sh usage error with wrong arg count" {
    run "$ACTION_DIR/run_tests.sh" "x"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

# --- install_deps.sh behavioral tests ---

@test "python: install_deps.sh uses 'uv sync' on the uv path" {
    install_python_shims
    local proj="$TMP_DIR/proj"
    write_pyproject "$proj"
    PATH="$PATH" run "$ACTION_DIR/install_deps.sh" "$proj" "true"
    [[ "$status" -eq 0 ]]
    grep -qE '^uv sync$' <<<"$output"
}

@test "python: install_deps.sh uses 'pip install -e .[test]' first on the pip path" {
    install_python_shims
    local proj="$TMP_DIR/proj"
    write_pyproject "$proj"
    PATH="$PATH" run "$ACTION_DIR/install_deps.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    grep -qE '^python -m pip install -e \.\[test\]$' <<<"$output"
    [[ "$output" == *"Installed with [test] extra"* ]]
}

@test "python: install_deps.sh falls back through [dev] to bare install on the pip path" {
    # When [test] and [dev] both fail (here, simulated by a pip shim that
    # exits 1 for the first two installs), the bare `pip install -e .`
    # path must still run — that's the contract for projects without
    # extras.
    install_python_shims
    # Replace the pip shim with one that fails the first two install -e
    # invocations and succeeds on the third (the bare install).
    cat > "$TMP_DIR/shim/python" <<'SHIM'
#!/bin/bash
printf 'python'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
case "${COUNTER_FILE:-/tmp/missing}" in /tmp/missing) ;; *) ;; esac
state="$TMP_DIR/pip_calls"
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" && "${3:-}" == "install" ]]; then
    count=$(($(cat "$state" 2>/dev/null || echo 0) + 1))
    echo "$count" > "$state"
    # First two "install -e .[...]" calls fail; third (bare) succeeds.
    # The very first call (pip install --upgrade pip) must still succeed.
    if [[ "${4:-}" == "--upgrade" ]]; then exit 0; fi
    case "$count" in
        2|3) exit 1 ;;
        *) exit 0 ;;
    esac
fi
exit 0
SHIM
    chmod +x "$TMP_DIR/shim/python"
    local proj="$TMP_DIR/proj"
    write_pyproject "$proj"
    TMP_DIR="$TMP_DIR" PATH="$PATH" run "$ACTION_DIR/install_deps.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Installed without test extras"* ]]
}

@test "python: install_deps.sh usage error with wrong arg count" {
    run "$ACTION_DIR/install_deps.sh" "x"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
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

@test "python: provenance job is gated on release-gate output" {
    # Provenance gates on the gate job's should-release output so adopters
    # can tighten the predicate via release-events without forking the workflow.
    run bash -c "sed -n '/^  provenance:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E \"if:.*should-release\""
    [[ "$status" -eq 0 ]]
}

@test "python: workflow has gate job calling release_gate" {
    run grep -E '^  gate:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep -E 'TomHennen/wrangle/actions/release_gate' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: build job needs gate so it can read should-release" {
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E 'needs:.*gate'"
    [[ "$status" -eq 0 ]]
}

@test "python: reusable workflow disables the uv cache for release builds" {
    # The composite's cache input must be driven by should-release:
    # 'disabled' on release, 'enabled' otherwise (SLSA_L3_AUDIT Finding 1).
    run bash -c "grep -E \"cache:.*should-release.*'disabled'.*'enabled'\" \"$WORKFLOW\""
    [[ "$status" -eq 0 ]]
}

@test "python: workflow exposes release-events input" {
    run grep -E '^      release-events:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: workflow exposes should-release output" {
    run grep -E '^      should-release:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: workflow exports hashes, provenance-artifact-name, metadata-artifact-name outputs" {
    run grep 'hashes:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'provenance-artifact-name:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'metadata-artifact-name:' "$WORKFLOW"
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

@test "python: example workflow does NOT install slsa-verifier (moved to reusable, #176)" {
    # Verification is now wrangle's responsibility; the example workflow's
    # publish job is just download-dist + pypi-publish. If the example
    # regrew per-adopter slsa-verifier wiring, that would be wasted work
    # AND would mask wrangle's verify-job failures by re-verifying.
    run grep 'slsa-verifier/actions/installer' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
    run grep 'slsa-verifier verify-artifact' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
}

@test "python: example workflow does NOT call SLSA generator (moved to reusable)" {
    # Provenance generation lives in wrangle's reusable workflow, not the example.
    run grep 'slsa-github-generator' "$EXAMPLE"
    [[ "$status" -ne 0 ]]
}

@test "python: reusable workflow has verify job calling slsa-verifier" {
    run grep -E '^  verify:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'slsa-verifier/actions/installer' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'slsa-verifier verify-artifact' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: verify job is gated on should-release AND verify-provenance" {
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E \"if:.*should-release.*verify-provenance\""
    [[ "$status" -eq 0 ]]
}

@test "python: workflow exposes verify-provenance input (default true)" {
    run grep -E '^      verify-provenance:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    # Find the boolean default — must be true.
    run bash -c "sed -n '/^      verify-provenance:/,/^      [a-z]/p' \"$WORKFLOW\" | grep -E 'default:[[:space:]]*true'"
    [[ "$status" -eq 0 ]]
}

@test "python: provenance job passes namespaced provenance-name to SLSA generator" {
    # actions/download-artifact picks non-deterministically when two artifacts
    # share a name in the same run. Multiple python builds in one workflow
    # would both produce 'multiple.intoto.jsonl' under the SLSA generator's
    # default. We pass provenance-name to namespace by shortname.
    run bash -c "sed -n '/^  provenance:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E 'provenance-name:.*shortname'"
    [[ "$status" -eq 0 ]]
}

@test "python: build job exposes shortname output" {
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E '^[[:space:]]*shortname:'"
    [[ "$status" -eq 0 ]]
}

@test "python: verify job depends on provenance and downloads its artifact" {
    # needs: must include 'provenance' so verify runs after the SLSA generator,
    # and the verify job must download the provenance artifact via its name
    # output (not hardcode the filename).
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$WORKFLOW\" | grep -E 'needs:.*provenance'"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  verify:/,/^[a-z]/p' \"$WORKFLOW\" | grep 'needs.provenance.outputs.provenance-name'"
    [[ "$status" -eq 0 ]]
}

@test "python: example workflow grants contents: write to build job" {
    # The SLSA generator's upload-assets job declares contents: write; GitHub
    # validates that the caller of wrangle's reusable workflow grants the same
    # at workflow startup, regardless of upload-assets being true or false.
    # Without this, adopters who copy the example hit startup_failure on the
    # first run. See PR #156's debugging history.
    run grep -E 'contents: write' "$EXAMPLE"
    [[ "$status" -eq 0 ]]
}

@test "python: README quick-start grants contents: write to build job" {
    # Same bug surface as the example workflow; if a user copies from the
    # README they should also see the correct permission set.
    run grep -E 'contents: write' "$REPO_ROOT/build/actions/python/README.md"
    [[ "$status" -eq 0 ]]
}

# --- Workflow-command-injection guard (#225 / SLSA_L3_AUDIT.md Finding 3) ---

@test "python: stop-commands guard helper exists and is executable" {
    [[ -x "$REPO_ROOT/lib/stop_commands_guard.sh" ]]
}

@test "python: install_deps.sh runs under the stop-commands guard" {
    # install_deps.sh runs ecosystem build tooling (uv sync / pip install)
    # that executes build backends and dependency hooks. The
    # ::stop-commands:: guard neutralizes workflow-command injection via
    # their stdout. See docs/SLSA_L3_AUDIT.md Finding 3.
    run grep -E 'lib/stop_commands_guard\.sh" run' "$ACTION"
    [[ "$status" -eq 0 ]]
    run bash -c "grep -A1 'stop_commands_guard.sh\" run' \"$ACTION\" | grep -F install_deps.sh"
    [[ "$status" -eq 0 ]]
}

@test "python: run_tests.sh runs under the stop-commands guard" {
    # pytest executes arbitrary project test code; the guard neutralizes
    # workflow-command injection via its stdout.
    run bash -c "grep -A1 'stop_commands_guard.sh\" run' \"$ACTION\" | grep -F run_tests.sh"
    [[ "$status" -eq 0 ]]
}
