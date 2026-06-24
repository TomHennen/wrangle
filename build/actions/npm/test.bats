#!/usr/bin/env bats

# Tests for the npm build action and reusable workflow.
#
# Three test layers, in increasing order of cost:
#   1. Pure-function tests that source detect_tooling.sh or
#      build_and_pack.sh and call their decision functions directly
#      (resolve_node_version, resolve_pm_cache, detect_pm, has_build_script,
#      has_real_test_script, find_one_tarball). Args in → stdout/exit out;
#      no shims, no GITHUB_OUTPUT plumbing.
#   2. Behavioral tests that invoke validate_inputs.sh end-to-end against
#      fixture project directories. validate_inputs.sh has no externally-
#      shimmed dependencies (just jq), so this layer needs no shims either.
#   3. Integration tests that exercise build_and_pack.sh's main() pipeline
#      via PATH shims for npm/pnpm — only the orchestration logic that
#      cannot be expressed as a pure function.
# Plus a thin layer of structural greps preserved only as supply-chain
# guard rails (no curl|sh, no /usr/local/bin, SHA-pinned actions,
# inputs flow through env:, action.yml delegates to the scripts the
# behavioral tests cover). End-to-end exercise lives in the wrangle-test
# companion repo.

setup_file() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    export ACTION_DIR
    # PATH shims for npm/pnpm used by the integration tests. The shims
    # echo their argv (so tests can assert which command ran) and, on
    # `pack`, plant a single placeholder tarball in dist/ to satisfy the
    # post-pack count check. Created once per file because they are
    # immutable; tests that need a different shim behavior (e.g., the
    # zero-tarball case) just don't exercise the pack codepath.
    mkdir -p "$BATS_FILE_TMPDIR/shim"
    cat > "$BATS_FILE_TMPDIR/shim/npm" <<'SHIM'
#!/bin/bash
printf 'npm'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "pack" ]]; then
        : > "dist/x-1.0.0.tgz"
        break
    fi
done
SHIM
    cat > "$BATS_FILE_TMPDIR/shim/pnpm" <<'SHIM'
#!/bin/bash
printf 'pnpm'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "pack" ]]; then
        : > "dist/x-1.0.0.tgz"
        break
    fi
done
SHIM
    chmod +x "$BATS_FILE_TMPDIR/shim/npm" "$BATS_FILE_TMPDIR/shim/pnpm"
    export SHIM_DIR="$BATS_FILE_TMPDIR/shim"
}

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    WORKFLOW="$REPO_ROOT/.github/workflows/build_and_publish_npm.yml"
    EXAMPLE="$REPO_ROOT/gh_workflow_examples/build_npm.yml"
    GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
    : > "$GITHUB_OUTPUT"
    export GITHUB_OUTPUT
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

@test "npm: detect_tooling.sh exists and is executable" {
    [[ -x "$ACTION_DIR/detect_tooling.sh" ]]
}

@test "npm: extract_metadata.sh exists and is executable" {
    [[ -x "$ACTION_DIR/extract_metadata.sh" ]]
}

@test "npm: action.yml delegates input validation to validate_inputs.sh" {
    run grep 'validate_inputs.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: action.yml delegates tooling detection to detect_tooling.sh" {
    run grep 'detect_tooling.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: action.yml delegates build/pack to build_and_pack.sh" {
    run grep 'build_and_pack.sh' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: action.yml uses actions/setup-node" {
    run grep 'actions/setup-node@' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: setup-node caching is conditional on package manager" {
    # Cache is driven dynamically by the tooling step's `cache` output.
    # The npm path emits `cache=npm`; the pnpm path emits `cache=` (empty)
    # so setup-node skips caching entirely. This is the load-bearing
    # protection against pnpm-store cache poisoning (issue #205).
    run grep -E "cache: \\\$\\{\\{ steps\\.tooling\\.outputs\\.cache \\}\\}" "$ACTION"
    [[ "$status" -eq 0 ]]
    # The action must NOT hard-code `cache: 'npm'` (or any literal cache
    # value) — that would re-enable caching for the pnpm path.
    run grep -E "^[[:space:]]*cache:[[:space:]]*['\"]?(npm|pnpm|yarn)['\"]?\$" "$ACTION"
    [[ "$status" -ne 0 ]]
}

@test "npm: action.yml does NOT enable pnpm-store cache anywhere" {
    # pnpm-store cache is the Mini Shai-Hulud / TanStack May 2026 cache-
    # poisoning vector. Wrangle must never enable it. See issue #205.
    # Pattern is anchored to the start of the line so prose in comments
    # that references the avoided `cache: 'pnpm'` pattern doesn't trip
    # the test that enforces it.
    run grep -E "^[[:space:]]*cache:[[:space:]]*['\"]?pnpm['\"]?[[:space:]]*\$" "$ACTION"
    [[ "$status" -ne 0 ]]
}

@test "npm: action.yml emits package-manager output for downstream visibility" {
    run grep -E 'package-manager:' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: action.yml conditionally enables Corepack for pnpm" {
    # Corepack provides pnpm on the runner. The step must be gated on
    # the detected package manager being pnpm so it doesn't run on
    # npm-only adopters.
    run grep -E "if: steps.tooling.outputs.package-manager == 'pnpm'" "$ACTION"
    [[ "$status" -eq 0 ]]
    run grep -E 'corepack enable' "$ACTION"
    [[ "$status" -eq 0 ]]
}

@test "npm: build_and_pack.sh asserts exactly one tarball in dist/ (not tail-n1)" {
    # Channel-free output: derives the tarball name from a glob over
    # dist/*.tgz and asserts the count is exactly 1 — catches surprise
    # multi-build scenarios (e.g., a future workspace change) explicitly,
    # instead of non-deterministically picking via `tail -n1`.
    #
    # Discovery lives in build_and_pack.sh (not in the action.yml run:
    # block) so that the count-check error printf — which echoes
    # filenames — runs INSIDE stop_commands_guard.sh. An unguarded
    # post-script discovery would let a hostile postinstall plant
    # `dist/::add-mask::evil.tgz` and inject a workflow command via the
    # error path's stderr.
    run grep -E 'expected exactly 1 tarball' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
    # And verify we are not relying on tail -n1 for the tarball capture.
    run grep -E 'tarball=.*tail' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -ne 0 ]]
    # The action.yml MUST NOT do its own post-script discovery — that
    # would put the filename-echoing error printf outside the guard.
    run grep -E 'expected exactly 1 tarball' "$ACTION"
    [[ "$status" -ne 0 ]]
}

@test "npm: build_and_pack.sh writes tarball=<name> to GITHUB_OUTPUT" {
    # The tarball-name output is consumed by the workflow's metadata-
    # artifact-name output and by the step summary. Discovery moved into
    # the script (see test above) means the GITHUB_OUTPUT write moves
    # too — both happen inside the guard.
    run grep -E 'tarball=.*GITHUB_OUTPUT' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
    # The action.yml's run: block must NOT also write tarball=...
    run bash -c "sed -n '/name: Build and pack/,/name: /p' \"$ACTION\" | grep -E 'tarball=.*GITHUB_OUTPUT'"
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

@test "npm: build_and_pack.sh uses null-safe jq for scripts.build/test detection" {
    # `(.scripts // {}) | has(...)` survives `"scripts": null` (or missing).
    run grep -E '\(\.scripts // \{\}\) \| has\("build"\)' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
    run grep -E '\(\.scripts // \{\}\) \| has\("test"\)' "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -eq 0 ]]
}

@test "npm: reusable workflow exposes ignore-scripts input that flows to composite" {
    # Workflow declares the input.
    run grep -E '^      ignore-scripts:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    # And forwards `inputs.ignore-scripts` through to the composite.
    run grep -E 'ignore-scripts:[[:space:]]*\$\{\{[[:space:]]*inputs\.ignore-scripts' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: passes inputs through env not interpolation" {
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

# --- validate_inputs.sh behavioral tests ---

# Helpers for fixture project directories.
write_pkg_json() {
    # $1: project dir, $2: optional extra JSON to merge into the base
    local dir="$1"
    local extra='{}'
    if [[ $# -ge 2 ]]; then
        extra="$2"
    fi
    mkdir -p "$dir"
    jq -n --argjson extra "$extra" \
        '{"name":"x","version":"1.0.0"} * $extra' > "$dir/package.json"
}

@test "npm: validate_inputs.sh accepts a package-lock.json project" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh accepts an npm-shrinkwrap.json project" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/npm-shrinkwrap.json"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh accepts a pnpm-lock.yaml project (v0.2)" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/pnpm-lock.yaml"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh rejects missing package.json" {
    local proj="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$proj"
    : > "$proj/package-lock.json"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no package.json found"* ]]
}

@test "npm: validate_inputs.sh rejects missing lockfile with install hint" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no lockfile found"* ]]
    [[ "$output" == *"npm install"* ]]
}

@test "npm: validate_inputs.sh rejects yarn.lock with a 'not supported' hint" {
    # Yarn is a follow-on. A yarn-only project must fail loudly, not fall
    # through to "no lockfile".
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/yarn.lock"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Yarn is not supported"* ]]
}

@test "npm: validate_inputs.sh rejects ambiguous npm + pnpm lockfile state" {
    # Having both lockfiles is unresolvable — wrangle can't infer the
    # adopter's intent. Picking one silently would silently determine
    # what gets attested.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    : > "$proj/pnpm-lock.yaml"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"both npm and pnpm lockfiles"* ]]
}

@test "npm: validate_inputs.sh rejects a workspaces project with the #208 link" {
    # Workspaces produce N tarballs; the single-tarball assertion in
    # action.yml and the downstream hash/SBOM/provenance pipeline assume
    # exactly 1. Reject before any of that runs.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"workspaces":["packages/*"]}'
    : > "$proj/package-lock.json"
    cd "$BATS_TEST_TMPDIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"workspaces"* ]]
    [[ "$output" == *"issues/208"* ]]
}

@test "npm: validate_inputs.sh usage error with no args" {
    run "$ACTION_DIR/validate_inputs.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

# --- detect_tooling.sh pure-function tests ---
#
# detect_tooling.sh splits its decision logic into resolve_node_version
# and resolve_pm_cache. Both are pure (args in → stdout out). The tests
# below source the script and call those functions directly, so they
# need neither a stub `node`/`jq` on PATH nor a GITHUB_OUTPUT file.
#
# Calling pattern: `run bash -c 'source script.sh; func "$@"' -- arg1 arg2`.
# The `--` placeholder makes "$0" inside bash -c a separator (bats convention),
# so the trailing args show up as "$@" inside the sourced script.

@test "npm: resolve_node_version: node-version input override wins over all other sources" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"engines":{"node":">=20"}}'
    printf '20\n' > "$proj/.nvmrc"
    run bash -c 'source "$1"; resolve_node_version "$2" "$3"' -- \
        "$ACTION_DIR/detect_tooling.sh" "22.5.1" "$proj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "22.5.1||Using node-version override: 22.5.1" ]]
}

@test "npm: resolve_node_version: uses .nvmrc when input is empty (preferred over engines.node)" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"engines":{"node":">=20"}}'
    printf '18.20.0\n' > "$proj/.nvmrc"
    run bash -c 'source "$1"; resolve_node_version "$2" "$3"' -- \
        "$ACTION_DIR/detect_tooling.sh" "" "$proj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "|$proj/.nvmrc|Using .nvmrc" ]]
}

@test "npm: resolve_node_version: uses engines.node when no .nvmrc and no input" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"engines":{"node":">=20"}}'
    run bash -c 'source "$1"; resolve_node_version "$2" "$3"' -- \
        "$ACTION_DIR/detect_tooling.sh" "" "$proj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "|$proj/package.json|Using engines.node from package.json" ]]
}

@test "npm: resolve_node_version: falls back to wrangle default when no version source" {
    # No .nvmrc, no engines.node, no input — setup-node would otherwise
    # emit a confusing "no version found" error. The fallback prevents that.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    run bash -c 'source "$1"; resolve_node_version "$2" "$3"' -- \
        "$ACTION_DIR/detect_tooling.sh" "" "$proj"
    [[ "$status" -eq 0 ]]
    # Format: "<version>||<reason mentioning the default>".
    [[ "$output" == *"||"* ]]
    [[ "$output" == *"falling back to wrangle default Node"* ]]
    # The version field must be a bare integer (the WRANGLE_DEFAULT_NODE).
    [[ "${output%%|*}" =~ ^[0-9]+$ ]]
}

@test "npm: resolve_pm_cache: npm-only project -> 'npm|npm' (cache safe with npm ci)" {
    # npm ci re-validates cached tarball integrity on every install,
    # so caching is safe.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    run bash -c 'source "$1"; resolve_pm_cache "$2"' -- \
        "$ACTION_DIR/detect_tooling.sh" "$proj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "npm|npm" ]]
}

@test "npm: resolve_pm_cache: pnpm project -> 'pnpm|' (cache deliberately EMPTY, issue #205)" {
    # pnpm-store has no install-time integrity re-verification, so wrangle
    # MUST NOT enable setup-node caching for the pnpm path — that's the
    # Mini Shai-Hulud / TanStack May 2026 cache-poisoning vector. The
    # empty second field tells setup-node to skip caching entirely.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/pnpm-lock.yaml"
    run bash -c 'source "$1"; resolve_pm_cache "$2"' -- \
        "$ACTION_DIR/detect_tooling.sh" "$proj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "pnpm|" ]]
    # Belt-and-braces: the second field must be empty, not any non-empty
    # cache value. A regression to "pnpm|pnpm" would re-open issue #205.
    [[ "${output#*|}" == "" ]]
}

# --- detect_tooling.sh end-to-end glue test ---

@test "npm: detect_tooling.sh writes all four expected lines to GITHUB_OUTPUT" {
    # One end-to-end test that the script wires the pure functions to
    # GITHUB_OUTPUT correctly. The branches themselves are covered by
    # the pure-function tests above; this just guards the glue.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    run "$ACTION_DIR/detect_tooling.sh" "$proj" ""
    [[ "$status" -eq 0 ]]
    grep -qE '^effective-version=[0-9]+$' "$GITHUB_OUTPUT"
    grep -qE '^effective-version-file=$' "$GITHUB_OUTPUT"
    grep -qE '^package-manager=npm$' "$GITHUB_OUTPUT"
    grep -qE '^cache=npm$' "$GITHUB_OUTPUT"
}

@test "npm: detect_tooling.sh usage error with wrong arg count" {
    run "$ACTION_DIR/detect_tooling.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

# --- build_and_pack.sh pure-function tests ---
#
# detect_pm, has_build_script, has_real_test_script, and find_one_tarball
# are pure — args in → stdout/exit out. Tests source the script and call
# them directly. No npm/pnpm shim needed for any of these.

@test "npm: detect_pm: returns npm for a package-lock.json project" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    run bash -c 'source "$1"; detect_pm "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "npm" ]]
}

@test "npm: detect_pm: returns pnpm for a pnpm-lock.yaml project" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    : > "$proj/pnpm-lock.yaml"
    run bash -c 'source "$1"; detect_pm "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "pnpm" ]]
}

@test "npm: has_build_script: true when package.json declares scripts.build" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"scripts":{"build":"true"}}'
    run bash -c 'source "$1"; has_build_script "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -eq 0 ]]
}

@test "npm: has_build_script: false when package.json has no scripts.build" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    run bash -c 'source "$1"; has_build_script "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -ne 0 ]]
}

@test "npm: has_build_script: false when scripts field is explicit null (null-safe jq)" {
    # The `(.scripts // {})` guard protects against `"scripts": null`. A
    # regression to `.scripts | has(...)` would crash on this fixture.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"scripts":null}'
    run bash -c 'source "$1"; has_build_script "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -ne 0 ]]
}

@test "npm: has_real_test_script: true for a custom test script" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"scripts":{"test":"jest"}}'
    run bash -c 'source "$1"; has_real_test_script "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -eq 0 ]]
}

@test "npm: has_real_test_script: false for npm's default 'no test specified' stub" {
    # The default stub exits 1 — an adopter who never ran `npm init` and
    # has the default test must not have wrangle invoke it. Substring
    # match so future-npm wording tweaks don't re-enable the no-op.
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" \
        '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}'
    run bash -c 'source "$1"; has_real_test_script "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -ne 0 ]]
}

@test "npm: has_real_test_script: false when no test script is declared" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj"
    run bash -c 'source "$1"; has_real_test_script "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -ne 0 ]]
}

@test "npm: find_one_tarball: prints the lone filename, stripped of dist/ prefix" {
    local proj="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$proj/dist"
    : > "$proj/dist/mypkg-2.3.4.tgz"
    run bash -c 'source "$1"; find_one_tarball "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "mypkg-2.3.4.tgz" ]]
}

@test "npm: find_one_tarball: errors when dist/ has zero tarballs" {
    # The post-pack count check catches a regressed pack flag (e.g., a
    # wrong --pack-destination) that lands the tarball outside dist/.
    # Without it, the action would proceed to hash an empty set.
    local proj="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$proj/dist"
    run bash -c 'source "$1"; find_one_tarball "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"expected exactly 1 tarball"* ]]
}

@test "npm: find_one_tarball: errors when dist/ has more than one tarball" {
    # Future-proofs against a workspaces regression (caught earlier by
    # validate_inputs.sh, but defense in depth).
    local proj="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$proj/dist"
    : > "$proj/dist/a-1.0.0.tgz"
    : > "$proj/dist/b-1.0.0.tgz"
    run bash -c 'source "$1"; find_one_tarball "$2"' -- \
        "$ACTION_DIR/build_and_pack.sh" "$proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"expected exactly 1 tarball"* ]]
}

# --- build_and_pack.sh integration tests (orchestration via PATH shim) ---
#
# Only the pipeline orchestration — what gets called, in what order, with
# which flags — still needs an npm/pnpm shim. The branching logic is
# covered above by the pure-function tests, so this layer is small.

@test "npm: build_and_pack.sh end-to-end npm pipeline: ci → build → test → pack → tarball=" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"scripts":{"build":"true","test":"jest"}}'
    : > "$proj/package-lock.json"
    PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "false"
    [[ "$status" -eq 0 ]]
    # Anchored line-by-line check: the shim echoes its argv on its own
    # line, so anchoring rules out matches inside status messages.
    grep -qE '^npm ci$' <<<"$output"
    grep -qE '^npm run build$' <<<"$output"
    grep -qE '^npm test$' <<<"$output"
    grep -qE '^npm pack --pack-destination dist$' <<<"$output"
    # No pnpm invocations should leak into the npm path.
    if grep -qE '^pnpm ' <<<"$output"; then return 1; fi
    grep -q '^tarball=x-1.0.0.tgz$' "$GITHUB_OUTPUT"
}

@test "npm: build_and_pack.sh end-to-end pnpm pipeline: install → build → test → pack" {
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"scripts":{"build":"true","test":"vitest"}}'
    : > "$proj/pnpm-lock.yaml"
    PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "false"
    [[ "$status" -eq 0 ]]
    grep -qE '^pnpm install --frozen-lockfile$' <<<"$output"
    grep -qE '^pnpm run build$' <<<"$output"
    grep -qE '^pnpm test$' <<<"$output"
    grep -qE '^pnpm pack --pack-destination dist$' <<<"$output"
    # No npm invocations should leak into the pnpm path.
    ! grep -qE '^npm ' <<<"$output"
}

@test "npm: build_and_pack.sh works with a RELATIVE subdir path (regression: PR #236 cd-doubling)" {
    # The original refactor of #236 called the pure helpers with
    # $input_path AFTER `cd "$input_path"`, so jq looked for
    # $input_path/$input_path/package.json. `set -e` does not propagate
    # into command-substitution subshells, so has_*_script silently
    # returned false — build and test were skipped and the action still
    # exited 0. Absolute-path test fixtures hid the bug because
    # `cd /abs/path` from any cwd resolves to the same place.
    #
    # This test invokes the script from a parent dir with the project
    # as a RELATIVE subdir name, the same shape an adopter using
    # `path: src` would hit.
    local proj="$BATS_TEST_TMPDIR/parent/src"
    write_pkg_json "$proj" '{"scripts":{"build":"true","test":"jest"}}'
    : > "$proj/package-lock.json"
    cd "$BATS_TEST_TMPDIR/parent"
    PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/build_and_pack.sh" "src" "true" "false"
    [[ "$status" -eq 0 ]]
    # The smoking-gun symptoms: build and test must have actually run,
    # and the jq path-not-found error must not appear.
    grep -qE '^npm run build$' <<<"$output"
    grep -qE '^npm test$' <<<"$output"
    if grep -qE 'Could not open file' <<<"$output"; then return 1; fi
    [[ "$output" != *"No build script in package.json"* ]]
    [[ "$output" != *"No non-default test script"* ]]
    grep -q '^tarball=x-1.0.0.tgz$' "$GITHUB_OUTPUT"
}

@test "npm: build_and_pack.sh threads --ignore-scripts through install AND pack" {
    # ignore-scripts means NO package.json script runs — not just transitive
    # hooks. Both install and pack must carry the flag, and `run build` /
    # `test` must be skipped entirely (no shim echo for either).
    local proj="$BATS_TEST_TMPDIR/proj"
    write_pkg_json "$proj" '{"scripts":{"build":"true","test":"jest"}}'
    : > "$proj/package-lock.json"
    PATH="$SHIM_DIR:$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "true"
    [[ "$status" -eq 0 ]]
    grep -qE '^npm ci --ignore-scripts$' <<<"$output"
    grep -qE '^npm pack --pack-destination dist --ignore-scripts$' <<<"$output"
    if grep -qE '^npm run build$' <<<"$output"; then return 1; fi
    if grep -qE '^npm test$' <<<"$output"; then return 1; fi
    [[ "$output" == *"Skipping npm run build and npm test"* ]]
}

@test "npm: build_and_pack.sh usage error with wrong arg count" {
    run "$ACTION_DIR/build_and_pack.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
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

@test "npm: workflow has no npm-registry publish job (Trusted Publishing OIDC constraint)" {
    # npm-registry publish must be in the adopter's workflow because npm's
    # Trusted Publishing validates the OIDC token's workflow_ref against the
    # caller's filename. The `publish` job here uploads to a GitHub release, so
    # assert no `npm publish` step.
    run grep -E 'npm publish' "$WORKFLOW"
    [[ "$status" -ne 0 ]]
}

@test "npm: workflow has a scan job using the scan action" {
    run grep -E '^  scan:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E 'uses:[[:space:]]*TomHennen/wrangle/actions/scan@'"
    [[ "$status" -eq 0 ]]
}

@test "npm: scan steps are gated on scan-tools so empty disables scanning" {
    # scan-tools: "" skips the scan step; the scan job then concludes success
    # and never blocks the attest/publish path.
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E \"if:.*inputs.scan-tools != ''\""
    [[ "$status" -eq 0 ]]
}

@test "npm: attest job needs scan (load-bearing finding blocks attestation + publish)" {
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E 'needs:.*scan'"
    [[ "$status" -eq 0 ]]
}

@test "npm: scan job needs prep so go-cache can read should-release" {
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E 'needs:.*prep'"
    [[ "$status" -eq 0 ]]
}

@test "npm: scan job forces go-cache off on release" {
    # The scan gates the attested release; its Go tool cache must build cold
    # on release so a poisoned cache cannot forge a passing scan.
    run bash -c "sed -n '/^  scan:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E \"go-cache:.*should-release == 'true' && ''\""
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow has prep job calling the prep action" {
    run grep -E '^  prep:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep -E 'TomHennen/wrangle/actions/prep@' "$WORKFLOW"
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

@test "npm: workflow exports hashes, metadata-artifact-name outputs" {
    run grep 'hashes:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'metadata-artifact-name:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow documents Trusted Publishing reusable workflow limitation" {
    run grep -E 'docs.npmjs.com/trusted-publishers|Trusted Publishing.*workflow_ref' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow pins every third-party action to a SHA (no tag exceptions)" {
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

@test "npm: workflow uploads SBOM/metadata, not just dist" {
    run grep -E 'metadata-dir|npm-metadata' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow namespaces artifacts by shortname, suffix-less at root" {
    # The scan/build jobs check out the ADOPTER repo, where lib/shortname.sh
    # is absent — the workflow must never source the lib (#469). Name
    # derivation is delegated to the prep job (which runs lib/derive_names.sh
    # from the wrangle checkout); downstream jobs read needs.prep.outputs.*.
    # Root build ('.') stays suffix-less.
    run grep -F 'source lib/shortname.sh' "$WORKFLOW"
    [[ "$status" -ne 0 ]]
    run grep -F 'TomHennen/wrangle/actions/prep@' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep -F 'build-type: npm' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: extract_metadata.sh at root emits empty shortname and clean dir" {
    cd "$BATS_TEST_TMPDIR"
    printf '{"version":"1.2.3"}' > package.json
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
    : > "$GITHUB_OUTPUT"
    run "$ACTION_DIR/extract_metadata.sh" "."
    [[ "$status" -eq 0 ]]
    grep -qE '^shortname=$' "$GITHUB_OUTPUT"
    grep -qE '^metadata-dir=metadata/npm$' "$GITHUB_OUTPUT"
}

@test "npm: extract_metadata.sh in a subdir namespaces shortname and dir" {
    cd "$BATS_TEST_TMPDIR"
    mkdir -p pkg/foo
    printf '{"version":"1.2.3"}' > pkg/foo/package.json
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
    : > "$GITHUB_OUTPUT"
    run "$ACTION_DIR/extract_metadata.sh" "pkg/foo"
    [[ "$status" -eq 0 ]]
    grep -qE '^shortname=pkg_foo$' "$GITHUB_OUTPUT"
    grep -qE '^metadata-dir=metadata/npm/pkg_foo$' "$GITHUB_OUTPUT"
}

@test "npm: prep job exposes shortname output" {
    run bash -c "sed -n '/^  prep:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E '^[[:space:]]*shortname:'"
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
    # wrangle's verify job declares contents: write (it attaches the VSA to the
    # release on tags); GitHub validates that the caller of wrangle's reusable
    # workflow grants the same at workflow startup, regardless of the run's ref.
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

# --- Workflow-command-injection guard (#225 / SLSA_L3_AUDIT.md Finding 3) ---

@test "npm: stop-commands guard helper exists and is executable" {
    [[ -x "$REPO_ROOT/lib/stop_commands_guard.sh" ]]
}

@test "npm: build_and_pack.sh runs under the stop-commands guard" {
    # build_and_pack.sh runs ecosystem build tooling and arbitrary
    # package.json / transitive-dependency lifecycle scripts. The
    # ::stop-commands:: guard neutralizes workflow-command injection via
    # their stdout (a hook printing `::add-mask::` / `::set-output::`).
    # See docs/SLSA_L3_AUDIT.md Finding 3.
    run grep -E 'lib/stop_commands_guard\.sh" run' "$ACTION"
    [[ "$status" -eq 0 ]]
    # The guarded command (on the line after `... run`) must be build_and_pack.sh.
    run bash -c "grep -A1 'stop_commands_guard.sh\" run' \"$ACTION\" | grep -F build_and_pack.sh"
    [[ "$status" -eq 0 ]]
}

# --- attest-build-provenance (wrangle builder identity, #316) ---

@test "npm: attest job delegates to attest_provenance with dist/* subject" {
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -F 'TomHennen/wrangle/actions/attest_provenance@'"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -F 'subject-path: dist/*'"
    [[ "$status" -eq 0 ]]
}

@test "npm: attest job no longer references the verify_attestation action" {
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$WORKFLOW\" | grep 'TomHennen/wrangle/actions/verify_attestation@'"
    [[ "$status" -ne 0 ]]
}

@test "npm: workflow has NO provenance job and NO slsa generator/verifier ref" {
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

@test "npm: verify job threads the policy input, which defaults to the per-eco default tier" {
    run bash -c "sed -n '/^  verify:/,\$p' \"$WORKFLOW\" | grep -F 'policy: \${{ inputs.policy }}'"
    [[ "$status" -eq 0 ]]
    run bash -c "grep -F 'default: policies/wrangle-default-npm-v1.hjson' \"$WORKFLOW\""
    [[ "$status" -eq 0 ]]
}

@test "npm: verify job passes no collector (the attest-assembled bundle is the collector)" {
    # The attest-assembled bundle (provenance + signed metadata) verify reads is
    # the sole collector, so no separate provenance jsonl collector is wired.
    run bash -c "sed -n '/^  verify:/,\$p' \"$WORKFLOW\" | grep -E '^[[:space:]]+collector:'"
    [[ "$status" -ne 0 ]]
}

@test "npm: attest job exposes the bundle name the verify job needs" {
    # attest_provenance uploads the bundle; the job re-exports its name and the
    # verify job depends on attest.
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -F 'bundles-artifact-name: \${{ steps.attest.outputs.bundles-artifact-name }}'"
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  verify:/,\$p' \"$WORKFLOW\" | grep -E 'needs:.*attest'"
    [[ "$status" -eq 0 ]]
}

@test "npm: attest and verify jobs are gated on should-attest" {
    # Both signing jobs drop out unless prep's should-attest is true; otherwise a
    # private repo's release would still attempt to sign and leak to the public log.
    run bash -c "sed -n '/^  attest:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -F \"needs.prep.outputs.should-attest == 'true'\""
    [[ "$status" -eq 0 ]]
    run bash -c "sed -n '/^  verify:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -F \"needs.prep.outputs.should-attest == 'true'\""
    [[ "$status" -eq 0 ]]
}

@test "npm: workflow renames the attestation input to attest-and-verify" {
    run grep -E '^      attest-and-verify:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep -F 'inputs.attestation' "$WORKFLOW"
    [[ "$status" -ne 0 ]]
}

@test "npm: prep job exposes should-attest, wired into attest-and-verify" {
    run bash -c "sed -n '/^  prep:/,/^  [a-z]/p' \"$WORKFLOW\" | grep -E '^[[:space:]]*should-attest:'"
    [[ "$status" -eq 0 ]]
    run grep -F 'attest-and-verify: ${{ inputs.attest-and-verify }}' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "npm: verify holds id-token + attestations but NOT contents: write" {
    local job
    job="$(awk '/^  [a-z][a-z_-]*:$/ { in_section = ($0 == "  verify:") } in_section' "$WORKFLOW")"
    grep -qE '^      id-token: write' <<<"$job"
    grep -qE '^      attestations: write' <<<"$job"
    ! grep -qE '^      contents: write([[:space:]]|$)' <<<"$job"
}

@test "npm: only the publish job holds contents: write (least privilege)" {
    for job in scan build attest verify; do
        section="$(awk -v j="  $job:" '/^  [a-z][a-z_-]*:$/ { in_section = ($0 == j) } in_section' "$WORKFLOW")"
        ! grep -qE '^      contents: write([[:space:]]|$)' <<<"$section"
    done
    section="$(awk '/^  [a-z][a-z_-]*:$/ { in_section = ($0 == "  publish:") } in_section' "$WORKFLOW")"
    grep -qE '^      contents: write([[:space:]]|$)' <<<"$section"
}

@test "npm: publish job is the shared release-upload job (contents: write only, no signing)" {
    local job
    job="$(awk '/^  [a-z][a-z_-]*:$/ { in_section = ($0 == "  publish:") } in_section' "$WORKFLOW")"
    grep -qE '^      contents: write([[:space:]]|$)' <<<"$job"
    ! grep -qE '^      (id-token|attestations):' <<<"$job"
    grep -qF 'TomHennen/wrangle/actions/publish_release@' <<<"$job"
    grep -qF 'attest-and-verify: ${{ inputs.attest-and-verify }}' <<<"$job"
}

@test "npm: publish job is blocked on a failed verify (policy gate preserved)" {
    # LOAD-BEARING. publish must require verify success whenever attesting, and
    # the skipped-verify escape must be gated on should-attest != 'true'.
    local job
    job="$(awk '/^  [a-z][a-z_-]*:$/ { in_section = ($0 == "  publish:") } in_section' "$WORKFLOW")"
    grep -qF "needs.verify.result == 'success'" <<<"$job"
    grep -qF "needs.verify.result == 'skipped' && needs.prep.outputs.should-attest != 'true'" <<<"$job"
    grep -qF "needs.prep.outputs.should-release == 'true'" <<<"$job"
}
