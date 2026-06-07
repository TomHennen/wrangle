#!/usr/bin/env bats

# Tests for the Python build action and reusable workflow.
#
# Three test layers, in increasing order of cost:
#   1. Pure-function tests that source run_tests.sh and call its
#      should_run_pytest decision function directly. No shims required.
#   2. Behavioral tests that invoke validate_inputs.sh end-to-end against
#      fixture project directories. validate_inputs.sh has no external
#      dependencies beyond lib/validate_path.sh.
#   3. Integration tests for run_tests.sh and install_deps.sh that drive
#      the actual orchestration through PATH shims for `python`, `pytest`,
#      and `uv` (the test container doesn't ship a real Python toolchain).
# Plus a thin layer of structural greps preserved as supply-chain guard
# rails (no curl|sh, no /usr/local/bin, SHA-pinned actions, inputs flow
# through env:, action.yml delegates to the scripts the behavioral tests
# cover). End-to-end exercise lives in the wrangle-test companion repo.

setup_file() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    export ACTION_DIR
    # PATH shims for python, pytest, and uv used by the integration tests.
    # Each shim echoes its argv (so tests can assert which command ran);
    # the python shim additionally branches on a `WRANGLE_TEST_PIP_FAILS`
    # env var that listed install attempts should fail, used to exercise
    # install_deps.sh's [test] → [dev] → bare fallback chain. Built once
    # per file because the shims are immutable.
    mkdir -p "$BATS_FILE_TMPDIR/shim"
    cat > "$BATS_FILE_TMPDIR/shim/python" <<'SHIM'
#!/bin/bash
printf 'python'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
# `pip install` invocations: WRANGLE_TEST_PIP_FAILS is a comma-delimited
# list of pip-install call indices that should fail (1-based, counting
# only `pip install` invocations — `pip install --upgrade pip` is
# skipped). Default: every install succeeds.
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" && "${3:-}" == "install" ]]; then
    if [[ "${4:-}" != "--upgrade" ]]; then
        counter="${WRANGLE_TEST_PIP_COUNTER:-/dev/null}"
        n=$(($(cat "$counter" 2>/dev/null || echo 0) + 1))
        printf '%d' "$n" > "$counter" 2>/dev/null || true
        fails=",${WRANGLE_TEST_PIP_FAILS:-},"
        if [[ "$fails" == *",$n,"* ]]; then exit 1; fi
    fi
fi
exit 0
SHIM
    cat > "$BATS_FILE_TMPDIR/shim/pytest" <<'SHIM'
#!/bin/bash
printf 'pytest'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
exit 0
SHIM
    cat > "$BATS_FILE_TMPDIR/shim/uv" <<'SHIM'
#!/bin/bash
printf 'uv'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
exit 0
SHIM
    chmod +x "$BATS_FILE_TMPDIR/shim/python" \
        "$BATS_FILE_TMPDIR/shim/pytest" \
        "$BATS_FILE_TMPDIR/shim/uv"
    export SHIM_DIR="$BATS_FILE_TMPDIR/shim"
}

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    WORKFLOW="$REPO_ROOT/.github/workflows/build_and_publish_python.yml"
    EXAMPLE="$REPO_ROOT/gh_workflow_examples/build_python.yml"
    GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
    : > "$GITHUB_OUTPUT"
    export GITHUB_OUTPUT
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

# --- run_tests.sh pure-function tests ---
#
# run_tests.sh's test-discovery decision lives in `should_run_pytest`,
# a pure function. The tests below source the script and call that
# function directly with fixture project directories — no pytest/uv
# shim needed for any of these.

write_pyproject() {
    # $1: project dir, $2: optional extra TOML appended to the file
    local dir="$1" extra="${2:-}"
    mkdir -p "$dir"
    {
        printf '[project]\nname = "x"\nversion = "0.1.0"\n'
        printf '%s' "$extra"
    } > "$dir/pyproject.toml"
}

@test "python: should_run_pytest: true when tests/ directory exists" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    mkdir -p "$proj/tests"
    run bash -c 'source "$1"; should_run_pytest "$2"' -- \
        "$ACTION_DIR/run_tests.sh" "$proj"
    [[ "$status" -eq 0 ]]
}

@test "python: should_run_pytest: true for pytest's default singular test/ form" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    mkdir -p "$proj/test"
    run bash -c 'source "$1"; should_run_pytest "$2"' -- \
        "$ACTION_DIR/run_tests.sh" "$proj"
    [[ "$status" -eq 0 ]]
}

@test "python: should_run_pytest: true when [tool.pytest.*] config is in pyproject.toml" {
    # A project that stores tests outside tests/ or test/ should still
    # have its suite run, provided pyproject.toml configures pytest.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj" $'\n[tool.pytest.ini_options]\ntestpaths = ["mytests"]\n'
    run bash -c 'source "$1"; should_run_pytest "$2"' -- \
        "$ACTION_DIR/run_tests.sh" "$proj"
    [[ "$status" -eq 0 ]]
}

@test "python: should_run_pytest: false when no tests/ and no [tool.pytest] config" {
    # No tests is not an error — same behavior as the shell build skipping
    # when no .bats files exist.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    run bash -c 'source "$1"; should_run_pytest "$2"' -- \
        "$ACTION_DIR/run_tests.sh" "$proj"
    [[ "$status" -ne 0 ]]
}

@test "python: should_run_pytest: NOT triggered by literal '[tool.pytest' inside a string value" {
    # The original `grep -qF '[tool.pytest'` was a fixed-substring match
    # that would match anywhere in the file — even inside a description
    # string. The anchored grep restricts to start-of-line TOML headers
    # so a description like 'A guide to [tool.pytest configuration]'
    # doesn't accidentally turn on test discovery.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj" $'description = "Notes on [tool.pytest configuration]"\n'
    run bash -c 'source "$1"; should_run_pytest "$2"' -- \
        "$ACTION_DIR/run_tests.sh" "$proj"
    [[ "$status" -ne 0 ]]
}

# --- run_tests.sh integration tests (shim) ---

@test "python: run_tests.sh end-to-end: invokes python -m pytest on the pip path" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    mkdir -p "$proj/tests"
    PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/run_tests.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    grep -qE '^python -m pytest$' <<<"$output"
    ! grep -qE '^uv ' <<<"$output"
}

@test "python: run_tests.sh end-to-end: invokes 'uv run pytest' on the uv path" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    mkdir -p "$proj/tests"
    PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/run_tests.sh" "$proj" "true"
    [[ "$status" -eq 0 ]]
    grep -qE '^uv run pytest$' <<<"$output"
    ! grep -qE '^python -m pytest$' <<<"$output"
}

@test "python: run_tests.sh end-to-end: prints skipping message when no tests detected" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/run_tests.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    ! grep -qE '^pytest' <<<"$output"
    ! grep -qE '^python -m pytest$' <<<"$output"
    [[ "$output" == *"skipping pytest"* ]]
}

@test "python: run_tests.sh usage error with wrong arg count" {
    run "$ACTION_DIR/run_tests.sh" "x"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

# --- install_deps.sh behavioral tests ---
#
# install_deps.sh is a thin orchestration script that shells out to
# `uv sync` or to a 4-call pip sequence (`pip install --upgrade pip`,
# then `[test]` → `[dev]` → bare). It has no pure decision functions
# worth extracting; the value of behavioral tests here is exercising
# the fallback chain. Pip-exit-code simulation is driven by the
# WRANGLE_TEST_PIP_FAILS env var the python shim reads.

@test "python: install_deps.sh uses 'uv sync' on the uv path" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/install_deps.sh" "$proj" "true"
    [[ "$status" -eq 0 ]]
    grep -qE '^uv sync$' <<<"$output"
    ! grep -qE '^python -m pip ' <<<"$output"
}

@test "python: install_deps.sh tries 'pip install -e .[test]' first on the pip path" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    WRANGLE_TEST_PIP_COUNTER="$BATS_TEST_TMPDIR/pip_calls" \
        PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/install_deps.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    grep -qE '^python -m pip install -e \.\[test\]$' <<<"$output"
    [[ "$output" == *"Installed with [test] extra"* ]]
    # Bare install must NOT have run.
    ! grep -qE '^python -m pip install -e \.$' <<<"$output"
}

@test "python: install_deps.sh falls back to '[dev]' when '[test]' fails" {
    # WRANGLE_TEST_PIP_FAILS=1 -> the first counted pip install (the
    # [test] one; `pip install --upgrade pip` is uncounted) fails.
    # install_deps must then try [dev], which succeeds, and the bare
    # install must NOT run.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    WRANGLE_TEST_PIP_COUNTER="$BATS_TEST_TMPDIR/pip_calls" \
        WRANGLE_TEST_PIP_FAILS="1" \
        PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/install_deps.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    grep -qE '^python -m pip install -e \.\[test\]$' <<<"$output"
    grep -qE '^python -m pip install -e \.\[dev\]$' <<<"$output"
    [[ "$output" == *"Installed with [dev] extra"* ]]
    ! grep -qE '^python -m pip install -e \.$' <<<"$output"
}

@test "python: install_deps.sh falls all the way through to bare install when both extras fail" {
    # WRANGLE_TEST_PIP_FAILS=1,2 -> [test] (call 1) and [dev] (call 2)
    # both fail; the bare install (call 3) succeeds. Asserts the full
    # cascade — closes the gap the original test left open in the middle.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pyproject "$proj"
    WRANGLE_TEST_PIP_COUNTER="$BATS_TEST_TMPDIR/pip_calls" \
        WRANGLE_TEST_PIP_FAILS="1,2" \
        PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/install_deps.sh" "$proj" "false"
    [[ "$status" -eq 0 ]]
    grep -qE '^python -m pip install -e \.\[test\]$' <<<"$output"
    grep -qE '^python -m pip install -e \.\[dev\]$' <<<"$output"
    grep -qE '^python -m pip install -e \.$' <<<"$output"
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

@test "python: workflow pins every third-party action to a SHA (no tag exceptions)" {
    # attest-build-provenance is now the sole provenance; the old
    # tag-pinned slsa-github-generator carve-out is gone, so every
    # third-party uses: must be a 40-hex SHA. wrangle self-refs are
    # already SHA-pinned (@<sha> # main).
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]
    # And the generator must be gone entirely.
    run grep 'slsa-github-generator' "$WORKFLOW"
    [[ "$status" -ne 0 ]]
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

@test "python: build job exposes shortname output" {
    run bash -c "sed -n '/^  build:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E '^[[:space:]]*shortname:'"
    [[ "$status" -eq 0 ]]
}

@test "python: example workflow grants contents: write to build job" {
    # wrangle's verify job declares contents: write (it attaches the VSA to the
    # release on tags); GitHub validates that the caller of wrangle's reusable
    # workflow grants the same at workflow startup, regardless of the run's ref.
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

# --- attest-build-provenance (wrangle builder identity, #316) ---

@test "python: workflow has attest job producing GitHub attest-build-provenance" {
    run grep -E '^  attest:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'actions/attest-build-provenance@' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "python: attest job is gated on should-release" {
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E 'if:.*should-release'"
    [[ "$status" -eq 0 ]]
}

@test "python: attest job no longer references the verify_attestation action" {
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$WORKFLOW\" | grep 'TomHennen/wrangle/actions/verify_attestation@'"
    [[ "$status" -ne 0 ]]
}

@test "python: workflow has NO provenance job and NO slsa generator/verifier ref" {
    # attest-build-provenance is the sole provenance; the verify job is the sole
    # verify. Patterns are narrow on purpose: a bare `slsa-verifier` would
    # false-fail on the workflow comment that names the old verifier job in prose.
    run grep -E '^  provenance:' "$WORKFLOW"
    [[ "$status" -ne 0 ]]
    run grep 'slsa-github-generator' "$WORKFLOW"
    [[ "$status" -ne 0 ]]
    run grep 'slsa-verifier/actions' "$WORKFLOW"
    [[ "$status" -ne 0 ]]
}

@test "python: verify job references the per-eco provenance policy" {
    run bash -c "sed -n '/^  verify:/,\$p' \"$WORKFLOW\" | grep -F 'policy: policies/wrangle-provenance-python-v1.hjson'"
    [[ "$status" -eq 0 ]]
}

@test "python: verify job collects the staged bundle via the jsonl collector" {
    # The bundle the attest job staged is read back as one-JSON-per-line.
    run bash -c "sed -n '/^  verify:/,\$p' \"$WORKFLOW\" | grep -F 'collector: jsonl:provenance/provenance.jsonl'"
    [[ "$status" -eq 0 ]]
}

@test "python: attest job uploads the provenance bundle the verify job needs" {
    # The verify job depends on attest and reads its uploaded bundle artifact.
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E 'name: python-provenance-bundle-'"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  verify:/,\$p' \"$WORKFLOW\" | grep -E 'needs:.*attest'"
    [[ "$status" -eq 0 ]]
}
