#!/bin/bash
# Runs the npm build pipeline: lockfile-faithful install, optional build,
# optional test, then pack to produce the tarball in dist/.
#
# v0.2 supports both npm and pnpm. The package manager is detected from
# the lockfile (validate_inputs.sh ensures exactly one is present):
#   - package-lock.json or npm-shrinkwrap.json -> npm (npm ci + npm pack)
#   - pnpm-lock.yaml                            -> pnpm (pnpm install
#                                                  --frozen-lockfile +
#                                                  pnpm pack)
#
# For pnpm, the version is determined by the adopter's `packageManager`
# field in package.json if set (Corepack reads it). If unset, Corepack's
# bundled default is used. Adopters who want deterministic builds should
# set `packageManager` per https://nodejs.org/api/packages.html#packagemanager .
#
# Build and test are conditional on package.json declaring non-default
# scripts. The npm-default test script (a `no test specified` echo+exit
# stub) is detected and skipped — substring match so minor wording
# tweaks in future npm/pnpm releases don't accidentally re-enable the
# no-op. pnpm inherits the same default when no test is configured.
#
# Lifecycle hooks are honored by default: `prepare` and `prepack` fire
# during install / pack, just as they would for an adopter running
# these commands locally. The L3 attestation thus binds to "what
# wrangle built from this commit's source + lockfile" — which is what
# the source-control review process expects.
#
# Adopters who want the stricter "source bytes only, no script execution"
# model pass ignore_scripts="true". When true, NOTHING in package.json's
# `scripts` field runs: install + pack get `--ignore-scripts`, AND
# `npm/pnpm run build` / `npm/pnpm test` are skipped entirely. The L3
# attestation then binds to "what pack produces against this source with
# no script execution at all." If finer-grained control is needed later
# (e.g., suppress hooks but still run the user's build), it can be added
# as a separate input.
#
# Tarball lands in dist/ (matching python's layout) so the reusable
# workflow can upload `${path}/dist/` symmetrically with python and
# slsa-verifier matches subjects against bare filenames. This script
# also handles tarball discovery — globs dist/*.tgz, asserts exactly
# one match, and writes `tarball=<filename>` to $GITHUB_OUTPUT — so
# that every step that touches the (possibly attacker-influenced)
# filename runs inside the caller's stop_commands_guard.sh wrap. A
# malicious package.json hook could otherwise plant a file named
# `::add-mask::evil.tgz` in dist/, and an unguarded post-script printf
# of that name would let the runner interpret the workflow command. By
# keeping discovery inside the script, the action.yml's run: block
# emits nothing after the guard returns. Tarball name still does not
# reach stdout (it goes to $GITHUB_OUTPUT, a file the runner reads).
#
# Usage: build/actions/npm/build_and_pack.sh <path> <run_tests> <ignore_scripts>
#   path:            project directory (already validated)
#   run_tests:       "true" to run the test script if a non-default test
#                    script exists, anything else to skip. Ignored when
#                    ignore_scripts is "true" (no script runs at all).
#   ignore_scripts:  "true" to skip every package.json script: pass
#                    --ignore-scripts to install AND pack, AND skip
#                    run-build / test outright. Anything else runs the
#                    full pipeline with lifecycle hooks honored.

set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s <path> <run_tests> <ignore_scripts>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
RUN_TESTS="$2"
IGNORE_SCRIPTS="$3"

cd "$INPUT_PATH"

# Detect package manager from lockfile. validate_inputs.sh already
# ensured exactly one of the supported lockfiles is present (and that
# yarn.lock is not, and that both npm + pnpm lockfiles aren't present).
if [[ -f "pnpm-lock.yaml" ]]; then
    PM=pnpm
else
    PM=npm
fi
printf 'Package manager: %s\n' "$PM"

ignore_scripts_args=()
if [[ "$IGNORE_SCRIPTS" == "true" ]]; then
    ignore_scripts_args=(--ignore-scripts)
    printf 'ignore-scripts=true: all package.json scripts will be skipped\n'
fi

if [[ "$PM" == "pnpm" ]]; then
    printf 'Installing dependencies (pnpm install --frozen-lockfile)...\n'
    pnpm install --frozen-lockfile "${ignore_scripts_args[@]}"
else
    printf 'Installing dependencies (npm ci)...\n'
    npm ci "${ignore_scripts_args[@]}"
fi

if [[ "$IGNORE_SCRIPTS" == "true" ]]; then
    printf 'Skipping %s run build and %s test (ignore-scripts=true)\n' "$PM" "$PM"
else
    # Reflect on package.json to decide whether to run build/test scripts.
    # Using jq rather than catching `<pm> run`'s "missing script" exit code
    # keeps the logs clear — the action shouldn't print error output for
    # scripts that simply don't exist. `(.scripts // {})` keeps the path
    # safe when `scripts` is missing or explicitly null.
    HAS_BUILD="$(jq -r '(.scripts // {}) | has("build")' package.json)"
    HAS_TEST_SCRIPT="$(jq -r '(.scripts // {}) | has("test")' package.json)"
    TEST_CMD="$(jq -r '.scripts.test // ""' package.json)"

    if [[ "$HAS_BUILD" == "true" ]]; then
        printf 'Running %s run build...\n' "$PM"
        "$PM" run build
    else
        printf 'No build script in package.json — skipping build step\n'
    fi

    if [[ "$RUN_TESTS" == "true" ]]; then
        # Substring match against the npm-default no-op script. Catches
        # `echo "Error: no test specified" && exit 1` and tolerates minor
        # wording changes in future npm/pnpm versions.
        if [[ "$HAS_TEST_SCRIPT" == "true" ]] && [[ "$TEST_CMD" != *'no test specified'* ]]; then
            printf 'Running %s test...\n' "$PM"
            "$PM" test
        else
            printf 'No non-default test script in package.json — skipping tests\n'
        fi
    fi
fi

printf 'Packing tarball into dist/ (%s pack)...\n' "$PM"
mkdir -p dist
# `<pm> pack --pack-destination dist` writes the tarball to dist/.
# --ignore-scripts (when set) suppresses prepack/postpack/prepare on
# the pack side too for both npm and pnpm.
"$PM" pack --pack-destination dist "${ignore_scripts_args[@]}"

# Discover the tarball. Done in this script (inside the caller's
# stop_commands_guard.sh wrap) rather than in action.yml so the count-
# check error path's stderr printf cannot leak a malicious filename
# (e.g., `dist/::add-mask::SECRET.tgz` planted by a hostile postinstall
# hook) past the guard and into the runner's workflow-command parser.
# nullglob expands `*.tgz` to nothing rather than the literal pattern
# when dist/ is empty, so the count check works cleanly in both cases.
shopt -s nullglob
tarballs=(dist/*.tgz)
if (( ${#tarballs[@]} != 1 )); then
    printf 'Error: expected exactly 1 tarball in dist/, found %d:\n' "${#tarballs[@]}" >&2
    printf '  %s\n' "${tarballs[@]}" >&2
    exit 1
fi

# Strip the dist/ prefix so the output matches the action.yml's previous
# `cd "$INPUT_PATH/dist"; tarball=*.tgz` contract — downstream steps
# (hash, SBOM, attach) expect a bare filename relative to dist/.
TARBALL="${tarballs[0]#dist/}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    # File-based output (not the ::set-output:: stdout command), so this
    # write is unaffected by the stop-commands suspension.
    printf 'tarball=%s\n' "$TARBALL" >> "$GITHUB_OUTPUT"
fi
