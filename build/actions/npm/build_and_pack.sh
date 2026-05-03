#!/bin/bash
# Runs the npm build pipeline: lockfile-faithful install, optional build,
# optional test, then `npm pack` to produce the tarball in dist/.
#
# Build and test are conditional on package.json declaring non-default
# scripts. The npm default test script (`echo "Error: no test specified"
# && exit 1`) is detected and skipped — same shape as python's
# tests-detection logic.
#
# Tarball lands in dist/ (matching python's layout) so the reusable
# workflow can upload `${path}/dist/` symmetrically with python and
# slsa-verifier matches subjects against bare filenames.
#
# Outputs the produced .tgz filename on stdout's last line so the caller
# can capture it; emits progress messages on stderr.
#
# Usage: build/actions/npm/build_and_pack.sh <path> <run_tests>
#   path:       project directory (already validated)
#   run_tests:  "true" to run npm test if a non-default test script exists,
#               anything else to skip

set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <path> <run_tests>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
RUN_TESTS="$2"

cd "$INPUT_PATH"

printf 'Installing dependencies (npm ci)...\n' >&2
npm ci

# Reflect on package.json to decide whether to run build/test scripts.
# Using jq rather than catching `npm run`'s "missing script" exit code
# keeps the logs clear — the action shouldn't print error output for
# scripts that simply don't exist.
HAS_BUILD="$(jq -r 'has("scripts") and (.scripts | has("build"))' package.json)"
HAS_TEST_SCRIPT="$(jq -r 'has("scripts") and (.scripts | has("test"))' package.json)"
TEST_CMD="$(jq -r '.scripts.test // ""' package.json)"
DEFAULT_TEST_CMD='echo "Error: no test specified" && exit 1'

if [[ "$HAS_BUILD" == "true" ]]; then
    printf 'Running npm run build...\n' >&2
    npm run build
else
    printf 'No build script in package.json — skipping build step\n' >&2
fi

if [[ "$RUN_TESTS" == "true" ]]; then
    if [[ "$HAS_TEST_SCRIPT" == "true" ]] && [[ "$TEST_CMD" != "$DEFAULT_TEST_CMD" ]]; then
        printf 'Running npm test...\n' >&2
        npm test
    else
        printf 'No non-default test script in package.json — skipping tests\n' >&2
    fi
fi

printf 'Packing tarball into dist/ (npm pack)...\n' >&2
mkdir -p dist
# `npm pack --silent --pack-destination dist` writes the tarball to dist/
# and prints the filename (relative to the destination) on stdout. The
# --pack-destination flag is npm 9+; v0.1 requires npm CLI >= 11.5.1
# (Trusted Publishing requirement) so this is safely available.
TARBALL="$(npm pack --silent --pack-destination dist)"

printf 'Created dist/%s\n' "$TARBALL" >&2
printf '%s\n' "$TARBALL"
