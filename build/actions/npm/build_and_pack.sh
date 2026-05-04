#!/bin/bash
# Runs the npm build pipeline: lockfile-faithful install, optional build,
# optional test, then `npm pack` to produce the tarball in dist/.
#
# Build and test are conditional on package.json declaring non-default
# scripts. The npm default test script (a `no test specified` echo+exit
# stub) is detected and skipped — substring match so minor wording
# tweaks in future npm releases don't accidentally re-enable the no-op.
#
# Lifecycle hooks are honored by default: `prepare` and `prepack` fire
# during `npm ci` / `npm pack`, just as they would for an adopter
# running these commands locally. The L3 attestation thus binds to "what
# wrangle built from this commit's source + lockfile" — which is what
# the source-control review process expects. Adopters who want the
# stricter "source bytes only, no script execution" model pass
# ignore_scripts="true"; that adds `--ignore-scripts` to npm ci and
# npm pack.
#
# Tarball lands in dist/ (matching python's layout) so the reusable
# workflow can upload `${path}/dist/` symmetrically with python and
# slsa-verifier matches subjects against bare filenames. The action.yml
# locates the produced tarball via a glob over dist/*.tgz after this
# script returns — keeping the tarball name out of stdout means a stray
# stdout-bound printf elsewhere can't silently break the capture.
#
# Usage: build/actions/npm/build_and_pack.sh <path> <run_tests> <ignore_scripts>
#   path:            project directory (already validated)
#   run_tests:       "true" to run npm test if a non-default test script
#                    exists, anything else to skip
#   ignore_scripts:  "true" to pass --ignore-scripts to npm ci and
#                    npm pack (suppresses prepare/prepack/postpack/install
#                    hooks); anything else honors lifecycle hooks

set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s <path> <run_tests> <ignore_scripts>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
RUN_TESTS="$2"
IGNORE_SCRIPTS="$3"

cd "$INPUT_PATH"

ignore_scripts_args=()
if [[ "$IGNORE_SCRIPTS" == "true" ]]; then
    ignore_scripts_args=(--ignore-scripts)
    printf 'Lifecycle hooks suppressed (--ignore-scripts)\n'
fi

printf 'Installing dependencies (npm ci)...\n'
npm ci "${ignore_scripts_args[@]}"

# Reflect on package.json to decide whether to run build/test scripts.
# Using jq rather than catching `npm run`'s "missing script" exit code
# keeps the logs clear — the action shouldn't print error output for
# scripts that simply don't exist.
HAS_BUILD="$(jq -r 'has("scripts") and (.scripts | has("build"))' package.json)"
HAS_TEST_SCRIPT="$(jq -r 'has("scripts") and (.scripts | has("test"))' package.json)"
TEST_CMD="$(jq -r '.scripts.test // ""' package.json)"

if [[ "$HAS_BUILD" == "true" ]]; then
    printf 'Running npm run build...\n'
    npm run build
else
    printf 'No build script in package.json — skipping build step\n'
fi

if [[ "$RUN_TESTS" == "true" ]]; then
    # Substring match against the npm-default no-op script. Catches the
    # current `echo "Error: no test specified" && exit 1` and tolerates
    # minor wording changes in future npm versions.
    if [[ "$HAS_TEST_SCRIPT" == "true" ]] && [[ "$TEST_CMD" != *'no test specified'* ]]; then
        printf 'Running npm test...\n'
        npm test
    else
        printf 'No non-default test script in package.json — skipping tests\n'
    fi
fi

printf 'Packing tarball into dist/ (npm pack)...\n'
mkdir -p dist
# `npm pack --pack-destination dist` writes the tarball to dist/. Output
# parsing is the action.yml's job (glob over dist/*.tgz); this script
# only needs to exit 0 on success. --ignore-scripts (when set) suppresses
# prepack/postpack/prepare on the pack side too.
npm pack --pack-destination dist "${ignore_scripts_args[@]}"
