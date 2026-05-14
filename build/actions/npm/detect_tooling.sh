#!/bin/bash
# Detects which Node.js version setup-node should use, and which package
# manager + cache config wrangle should drive. Writes resolution to
# GITHUB_OUTPUT for the composite action's downstream steps.
#
# Node.js version resolution order:
#   1. node-version input override
#   2. .nvmrc in the project directory
#   3. engines.node in package.json
#   4. wrangle-default LTS — avoids setup-node's confusing "no version found"
#      error for projects that pin neither. Bumped wrangle-side as new LTS
#      releases land; adopters who care about a specific version should set
#      one of the first three explicitly.
#
# Package manager: pnpm-lock.yaml -> pnpm; otherwise npm. validate_inputs.sh
# has already rejected ambiguous and unsupported lockfile states.
#
# Cache config: emits `cache=` (empty) on the pnpm path so setup-node skips
# caching entirely. pnpm-store stores extracted modules under content-
# addressed paths and does NOT re-verify content matches the path's claimed
# hash at install time — exactly the cache-poisoning vector the May 2026
# Mini Shai-Hulud / TanStack compromise exploited. See:
#   https://github.com/TomHennen/wrangle/issues/205
# The npm path emits `cache=npm` because `npm ci` re-validates each cached
# tarball's integrity against package-lock.json on every install; pnpm
# install has no equivalent re-verification.
#
# Usage: build/actions/npm/detect_tooling.sh <path> <node-version-input>

set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <path> <node-version-input>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
INPUT_NODE_VERSION="$2"
WRANGLE_DEFAULT_NODE="22"

if [[ -n "$INPUT_NODE_VERSION" ]]; then
    printf 'effective-version=%s\n' "$INPUT_NODE_VERSION" >> "$GITHUB_OUTPUT"
    printf 'effective-version-file=\n' >> "$GITHUB_OUTPUT"
    printf 'Using node-version override: %s\n' "$INPUT_NODE_VERSION"
elif [[ -f "$INPUT_PATH/.nvmrc" ]]; then
    printf 'effective-version=\n' >> "$GITHUB_OUTPUT"
    printf 'effective-version-file=%s/.nvmrc\n' "$INPUT_PATH" >> "$GITHUB_OUTPUT"
    printf 'Using .nvmrc\n'
elif [[ -n "$(jq -r '.engines.node // empty' "$INPUT_PATH/package.json")" ]]; then
    printf 'effective-version=\n' >> "$GITHUB_OUTPUT"
    printf 'effective-version-file=%s/package.json\n' "$INPUT_PATH" >> "$GITHUB_OUTPUT"
    printf 'Using engines.node from package.json\n'
else
    printf 'effective-version=%s\n' "$WRANGLE_DEFAULT_NODE" >> "$GITHUB_OUTPUT"
    printf 'effective-version-file=\n' >> "$GITHUB_OUTPUT"
    printf 'No version hint in .nvmrc, engines.node, or node-version input — falling back to wrangle default Node %s\n' "$WRANGLE_DEFAULT_NODE"
fi

if [[ -f "$INPUT_PATH/pnpm-lock.yaml" ]]; then
    printf 'package-manager=pnpm\n' >> "$GITHUB_OUTPUT"
    printf 'cache=\n' >> "$GITHUB_OUTPUT"
    printf 'Detected pnpm-lock.yaml; using pnpm. setup-node caching deliberately disabled (see issue #205).\n'
else
    printf 'package-manager=npm\n' >> "$GITHUB_OUTPUT"
    printf 'cache=npm\n' >> "$GITHUB_OUTPUT"
    printf 'Detected npm lockfile; using npm with cache=npm.\n'
fi
