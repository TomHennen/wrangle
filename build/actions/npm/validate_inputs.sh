#!/bin/bash
# Validates inputs to the npm build action: shared path checks via
# lib/validate_path.sh, plus npm-specific checks that package.json exists
# and a lockfile is present (npm ci requires one).
#
# v0.1 supports npm only; pnpm and Yarn are follow-on. Detected by
# rejecting yarn.lock / pnpm-lock.yaml when no package-lock.json
# (or npm-shrinkwrap.json) is present.
#
# Usage: build/actions/npm/validate_inputs.sh <path>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <path>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/../../../lib/validate_path.sh" "$INPUT_PATH"

if [[ ! -f "$INPUT_PATH/package.json" ]]; then
    printf 'Error: no package.json found in %s\n' "$INPUT_PATH" >&2
    exit 1
fi

# v0.1 supports single-package npm only. A workspaces field would mean
# `npm pack` at the project root produces an empty-`files` tarball while
# `npm publish --workspaces` would publish N sub-packages — wrangle's
# attestation would not match what consumers download. Reject early
# rather than letting the L3 + verify pipeline run on the wrong bytes.
if [[ "$(jq -r 'has("workspaces")' "$INPUT_PATH/package.json")" == "true" ]]; then
    printf 'Error: workspaces field detected in %s/package.json; npm workspaces are not supported in v0.1.\n' "$INPUT_PATH" >&2
    printf 'Hint: file an issue if you need workspaces support.\n' >&2
    exit 1
fi

if [[ -f "$INPUT_PATH/package-lock.json" ]] || [[ -f "$INPUT_PATH/npm-shrinkwrap.json" ]]; then
    exit 0
fi

if [[ -f "$INPUT_PATH/pnpm-lock.yaml" ]]; then
    printf 'Error: pnpm-lock.yaml detected in %s; pnpm is not supported in v0.1.\n' "$INPUT_PATH" >&2
    printf 'Hint: file an issue if you need pnpm support.\n' >&2
    exit 1
fi
if [[ -f "$INPUT_PATH/yarn.lock" ]]; then
    printf 'Error: yarn.lock detected in %s; Yarn is not supported in v0.1.\n' "$INPUT_PATH" >&2
    printf 'Hint: file an issue if you need Yarn support.\n' >&2
    exit 1
fi

printf 'Error: no lockfile found in %s.\n' "$INPUT_PATH" >&2
# shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
printf 'Hint: npm ci requires package-lock.json or npm-shrinkwrap.json. Run `npm install` and commit the lockfile.\n' >&2
exit 1
