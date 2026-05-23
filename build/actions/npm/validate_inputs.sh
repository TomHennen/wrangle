#!/bin/bash
# Validates inputs to the npm build action: shared path checks via
# lib/validate_path.sh, plus npm-specific checks that package.json exists
# and a supported lockfile is present.
#
# v0.2 supports npm AND pnpm (single-package only). Yarn lockfiles are
# still rejected explicitly; Yarn support is a follow-on. Workspaces are
# also still rejected in v0.2 — tracked in #208.
#
# Ambiguous state (both package-lock.json AND pnpm-lock.yaml present) is
# rejected rather than silently picking one, because the adopter's intent
# isn't clear in that case.
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

# Workspaces support is tracked separately in #208. A workspaces project
# produces N tarballs from one build, which breaks the current single-
# tarball assertion in action.yml and propagates through hashing, SBOM,
# and provenance. Reject early rather than letting the L3 + verify
# pipeline run on the wrong bytes.
if [[ "$(jq -r 'has("workspaces")' "$INPUT_PATH/package.json")" == "true" ]]; then
    printf 'Error: workspaces field detected in %s/package.json; npm workspaces are not supported in v0.2.\n' "$INPUT_PATH" >&2
    printf 'Hint: workspaces support is tracked in https://github.com/TomHennen/wrangle/issues/208\n' >&2
    exit 1
fi

# Lockfile detection.
HAS_NPM_LOCK=false
HAS_PNPM_LOCK=false
if [[ -f "$INPUT_PATH/package-lock.json" ]] || [[ -f "$INPUT_PATH/npm-shrinkwrap.json" ]]; then
    HAS_NPM_LOCK=true
fi
if [[ -f "$INPUT_PATH/pnpm-lock.yaml" ]]; then
    HAS_PNPM_LOCK=true
fi

# Yarn lockfile rejection. Yarn support is a follow-on; reject explicitly
# so adopters get a clear error rather than a confusing "no lockfile".
if [[ -f "$INPUT_PATH/yarn.lock" ]]; then
    printf 'Error: yarn.lock detected in %s; Yarn is not supported in v0.2.\n' "$INPUT_PATH" >&2
    printf 'Hint: file an issue if you need Yarn support.\n' >&2
    exit 1
fi

# Ambiguous: both npm and pnpm lockfiles present. Wrangle can't tell
# which manager the adopter intends. Reject and let the adopter clean
# up rather than silently picking one (which would silently determine
# what gets attested).
if [[ "$HAS_NPM_LOCK" == "true" && "$HAS_PNPM_LOCK" == "true" ]]; then
    printf 'Error: both npm and pnpm lockfiles found in %s.\n' "$INPUT_PATH" >&2
    printf 'Hint: keep only one of package-lock.json / npm-shrinkwrap.json / pnpm-lock.yaml.\n' >&2
    printf '      If you migrated from npm to pnpm (or vice versa), delete the old lockfile.\n' >&2
    exit 1
fi

# Success: exactly one of the supported lockfiles is present.
if [[ "$HAS_NPM_LOCK" == "true" || "$HAS_PNPM_LOCK" == "true" ]]; then
    exit 0
fi

printf 'Error: no lockfile found in %s.\n' "$INPUT_PATH" >&2
# shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
printf 'Hint: install your dependencies (`npm install` or `pnpm install`) and commit the resulting lockfile.\n' >&2
exit 1
