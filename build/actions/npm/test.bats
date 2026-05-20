#!/usr/bin/env bats

# Tests for the npm build action and reusable workflow.
#
# Two test layers:
#   1. Behavioral tests that invoke validate_inputs.sh, detect_tooling.sh,
#      and build_and_pack.sh against fixture project directories and assert
#      on exit codes, GITHUB_OUTPUT contents, and produced artifacts.
#   2. Structural greps that remain only as supply-chain guard rails —
#      e.g., no curl|sh, no /usr/local/bin, SHA-pinned actions, action.yml
#      flows inputs through env: rather than direct interpolation, and
#      action.yml actually delegates to the scripts the behavioral tests
#      cover. End-to-end exercise lives in the wrangle-test companion repo.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
    ACTION="$ACTION_DIR/action.yml"
    WORKFLOW="$REPO_ROOT/.github/workflows/build_and_publish_npm.yml"
    EXAMPLE="$REPO_ROOT/gh_workflow_examples/build_npm.yml"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/npm-bats-XXXXXX")"
    GITHUB_OUTPUT="$TMP_DIR/github_output"
    : > "$GITHUB_OUTPUT"
    export GITHUB_OUTPUT
}

teardown() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
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
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    cd "$TMP_DIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh accepts an npm-shrinkwrap.json project" {
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/npm-shrinkwrap.json"
    cd "$TMP_DIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh accepts a pnpm-lock.yaml project (v0.2)" {
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/pnpm-lock.yaml"
    cd "$TMP_DIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -eq 0 ]]
}

@test "npm: validate_inputs.sh rejects missing package.json" {
    local proj="$TMP_DIR/proj"
    mkdir -p "$proj"
    : > "$proj/package-lock.json"
    cd "$TMP_DIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no package.json found"* ]]
}

@test "npm: validate_inputs.sh rejects missing lockfile with install hint" {
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    cd "$TMP_DIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no lockfile found"* ]]
    [[ "$output" == *"npm install"* ]]
}

@test "npm: validate_inputs.sh rejects yarn.lock with a 'not supported' hint" {
    # Yarn is a follow-on. A yarn-only project must fail loudly, not fall
    # through to "no lockfile".
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/yarn.lock"
    cd "$TMP_DIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Yarn is not supported"* ]]
}

@test "npm: validate_inputs.sh rejects ambiguous npm + pnpm lockfile state" {
    # Having both lockfiles is unresolvable — wrangle can't infer the
    # adopter's intent. Picking one silently would silently determine
    # what gets attested.
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    : > "$proj/pnpm-lock.yaml"
    cd "$TMP_DIR"
    run "$ACTION_DIR/validate_inputs.sh" "proj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"both npm and pnpm lockfiles"* ]]
}

@test "npm: validate_inputs.sh rejects a workspaces project with the #208 link" {
    # Workspaces produce N tarballs; the single-tarball assertion in
    # action.yml and the downstream hash/SBOM/provenance pipeline assume
    # exactly 1. Reject before any of that runs.
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"workspaces":["packages/*"]}'
    : > "$proj/package-lock.json"
    cd "$TMP_DIR"
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

# --- detect_tooling.sh behavioral tests ---

@test "npm: detect_tooling.sh node-version input override wins over all other sources" {
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"engines":{"node":">=20"}}'
    printf '20\n' > "$proj/.nvmrc"
    run "$ACTION_DIR/detect_tooling.sh" "$proj" "22.5.1"
    [[ "$status" -eq 0 ]]
    grep -q '^effective-version=22.5.1$' "$GITHUB_OUTPUT"
    grep -q '^effective-version-file=$' "$GITHUB_OUTPUT"
}

@test "npm: detect_tooling.sh uses .nvmrc when input is empty" {
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"engines":{"node":">=20"}}'
    printf '18.20.0\n' > "$proj/.nvmrc"
    run "$ACTION_DIR/detect_tooling.sh" "$proj" ""
    [[ "$status" -eq 0 ]]
    grep -q '^effective-version=$' "$GITHUB_OUTPUT"
    grep -q "^effective-version-file=$proj/.nvmrc$" "$GITHUB_OUTPUT"
}

@test "npm: detect_tooling.sh uses engines.node when no .nvmrc and no input" {
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"engines":{"node":">=20"}}'
    run "$ACTION_DIR/detect_tooling.sh" "$proj" ""
    [[ "$status" -eq 0 ]]
    grep -q '^effective-version=$' "$GITHUB_OUTPUT"
    grep -q "^effective-version-file=$proj/package.json$" "$GITHUB_OUTPUT"
}

@test "npm: detect_tooling.sh falls back to wrangle default Node when no version source" {
    # No .nvmrc, no engines.node, no input — setup-node would emit a
    # confusing "no version found" error. The fallback prevents that.
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    run "$ACTION_DIR/detect_tooling.sh" "$proj" ""
    [[ "$status" -eq 0 ]]
    grep -qE '^effective-version=[0-9]+$' "$GITHUB_OUTPUT"
    grep -q '^effective-version-file=$' "$GITHUB_OUTPUT"
    [[ "$output" == *"falling back to wrangle default"* ]]
}

@test "npm: detect_tooling.sh emits package-manager=npm and cache=npm for npm projects" {
    # npm ci re-validates cached tarball integrity on every install, so
    # caching is safe.
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    run "$ACTION_DIR/detect_tooling.sh" "$proj" ""
    [[ "$status" -eq 0 ]]
    grep -q '^package-manager=npm$' "$GITHUB_OUTPUT"
    grep -q '^cache=npm$' "$GITHUB_OUTPUT"
}

@test "npm: detect_tooling.sh emits package-manager=pnpm and EMPTY cache for pnpm projects" {
    # pnpm-store has no install-time integrity re-verification, so wrangle
    # must NOT enable setup-node caching for the pnpm path — that's the
    # Mini Shai-Hulud / TanStack cache-poisoning vector (issue #205). An
    # `cache=` (empty) line tells setup-node to skip caching entirely.
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/pnpm-lock.yaml"
    run "$ACTION_DIR/detect_tooling.sh" "$proj" ""
    [[ "$status" -eq 0 ]]
    grep -q '^package-manager=pnpm$' "$GITHUB_OUTPUT"
    grep -q '^cache=$' "$GITHUB_OUTPUT"
    # Belt and braces: cache must not be set to anything non-empty.
    ! grep -E '^cache=.+$' "$GITHUB_OUTPUT"
}

@test "npm: detect_tooling.sh usage error with wrong arg count" {
    run "$ACTION_DIR/detect_tooling.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage:"* ]]
}

# --- build_and_pack.sh behavioral tests ---
#
# build_and_pack.sh shells out to npm/pnpm/jq. Real npm/pnpm aren't
# available in the test container, so these tests put PATH shims for
# npm and pnpm ahead of the system PATH. jq stays real (it's pure and
# universally available); the script reads package.json via jq, so we
# write real package.json fixtures and assert that the shim recorded
# the expected commands.

install_pm_shim() {
    # Creates fake `npm` and `pnpm` binaries that record every invocation
    # to $TMP_DIR/calls.log and, on `pack`, plant a single tarball in
    # dist/ to satisfy the post-pack count check. Caller exports PATH.
    mkdir -p "$TMP_DIR/shim"
    cat > "$TMP_DIR/shim/npm" <<'SHIM'
#!/bin/bash
printf 'npm'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
# If this is a pack invocation, plant exactly one tarball in dist/.
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "pack" ]]; then
        : > "dist/x-1.0.0.tgz"
        break
    fi
done
SHIM
    cat > "$TMP_DIR/shim/pnpm" <<'SHIM'
#!/bin/bash
printf 'pnpm'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "pack" ]]; then
        : > "dist/x-1.0.0.tgz"
        break
    fi
done
SHIM
    chmod +x "$TMP_DIR/shim/npm" "$TMP_DIR/shim/pnpm"
    PATH="$TMP_DIR/shim:$PATH"
}

@test "npm: build_and_pack.sh runs npm ci, build, test, pack for an npm project" {
    install_pm_shim
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"scripts":{"build":"true","test":"true"}}'
    : > "$proj/package-lock.json"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "false"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"npm ci"* ]]
    [[ "$output" == *"npm run build"* ]]
    [[ "$output" == *"npm test"* ]]
    [[ "$output" == *"npm pack --pack-destination dist"* ]]
    grep -q '^tarball=x-1.0.0.tgz$' "$GITHUB_OUTPUT"
}

@test "npm: build_and_pack.sh runs pnpm install/build/test/pack for a pnpm project" {
    install_pm_shim
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"scripts":{"build":"true","test":"true"}}'
    : > "$proj/pnpm-lock.yaml"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "false"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"pnpm install --frozen-lockfile"* ]]
    [[ "$output" == *"pnpm run build"* ]]
    [[ "$output" == *"pnpm test"* ]]
    [[ "$output" == *"pnpm pack --pack-destination dist"* ]]
}

@test "npm: build_and_pack.sh threads --ignore-scripts through install AND pack" {
    install_pm_shim
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"scripts":{"build":"true","test":"true"}}'
    : > "$proj/package-lock.json"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "true"
    [[ "$status" -eq 0 ]]
    # Both ci and pack lines must carry --ignore-scripts.
    [[ "$output" == *"npm ci --ignore-scripts"* ]]
    [[ "$output" == *"npm pack --pack-destination dist --ignore-scripts"* ]]
}

@test "npm: build_and_pack.sh with ignore_scripts=true skips run-build and test entirely" {
    # ignore-scripts means NO package.json script runs — not just transitive
    # hooks. A regression that only adds --ignore-scripts to install but
    # still calls `npm run build` would defeat the stricter L3 contract.
    install_pm_shim
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"scripts":{"build":"true","test":"true"}}'
    : > "$proj/package-lock.json"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "true"
    [[ "$status" -eq 0 ]]
    # The shim echoes its argv on a line of its own (e.g., "npm run build").
    # An anchored grep distinguishes that from the "Skipping npm run build
    # and npm test" status line.
    ! grep -qE '^npm run build$' <<<"$output"
    ! grep -qE '^npm test$' <<<"$output"
    [[ "$output" == *"Skipping npm run build and npm test"* ]]
}

@test "npm: build_and_pack.sh skips build when package.json has no build script" {
    install_pm_shim
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "false"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"npm run build"* ]]
    [[ "$output" == *"No build script in package.json"* ]]
}

@test "npm: build_and_pack.sh skips npm's default 'no test specified' script" {
    # An adopter who never ran `npm init` and uses npm's default stub
    # test must not have wrangle invoke it (the stub exits 1).
    install_pm_shim
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}'
    : > "$proj/package-lock.json"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "false"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"npm test"* ]]
    [[ "$output" == *"No non-default test script"* ]]
}

@test "npm: build_and_pack.sh skips test when run_tests=false even if a test script exists" {
    install_pm_shim
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"scripts":{"test":"true"}}'
    : > "$proj/package-lock.json"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "false" "false"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"npm test"* ]]
}

@test "npm: build_and_pack.sh survives 'scripts': null in package.json" {
    # The null-safe jq guards (`(.scripts // {}) | has(...)`) protect
    # against the explicit-null case; a regression to `.scripts | has(...)`
    # would crash on this fixture.
    install_pm_shim
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj" '{"scripts":null}'
    : > "$proj/package-lock.json"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "true" "false"
    [[ "$status" -eq 0 ]]
}

@test "npm: build_and_pack.sh errors when pack produces zero tarballs" {
    # The post-pack count check is what catches a regressed pack flag
    # (e.g., wrong --pack-destination) that lands the tarball outside
    # dist/. Without it, the action would proceed to hash an empty set.
    install_pm_shim
    # Override npm to NOT plant a tarball on pack.
    cat > "$TMP_DIR/shim/npm" <<'SHIM'
#!/bin/bash
printf 'npm'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
SHIM
    chmod +x "$TMP_DIR/shim/npm"
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "false" "false"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"expected exactly 1 tarball"* ]]
}

@test "npm: build_and_pack.sh errors when pack produces more than one tarball" {
    # Future-proofs against a workspaces regression (caught earlier by
    # validate_inputs.sh, but defense in depth).
    install_pm_shim
    # Override npm to plant TWO tarballs.
    cat > "$TMP_DIR/shim/npm" <<'SHIM'
#!/bin/bash
printf 'npm'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "pack" ]]; then
        : > "dist/a-1.0.0.tgz"
        : > "dist/b-1.0.0.tgz"
        break
    fi
done
SHIM
    chmod +x "$TMP_DIR/shim/npm"
    local proj="$TMP_DIR/proj"
    write_pkg_json "$proj"
    : > "$proj/package-lock.json"
    PATH="$PATH" run "$ACTION_DIR/build_and_pack.sh" "$proj" "false" "false"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"expected exactly 1 tarball"* ]]
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
