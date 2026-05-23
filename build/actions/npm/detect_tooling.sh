#!/bin/bash
# Detects which Node.js version setup-node should use, and which package
# manager + cache config wrangle should drive. Writes resolution to
# GITHUB_OUTPUT for the composite action's downstream steps.
#
# The two decisions are split into pure functions — `resolve_node_version`
# and `resolve_pm_cache` — so test.bats can exercise the branches directly
# without staging GITHUB_OUTPUT or shimming any external tool. The
# functions take their inputs as args and print their outputs on stdout;
# the file's `main` glues them to the action's GITHUB_OUTPUT contract.
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

WRANGLE_DEFAULT_NODE="22"

# Pure function: resolves which Node.js version source setup-node should
# use. Prints exactly one line: "<effective-version>|<effective-version-file>|<reason>".
# Either effective-version or effective-version-file is populated, never both.
#
# Args: <input_version> <project_dir>
resolve_node_version() {
    local input="$1" path="$2"
    if [[ -n "$input" ]]; then
        printf '%s||Using node-version override: %s\n' "$input" "$input"
    elif [[ -f "$path/.nvmrc" ]]; then
        printf '|%s/.nvmrc|Using .nvmrc\n' "$path"
    elif [[ -n "$(jq -r '.engines.node // empty' "$path/package.json")" ]]; then
        printf '|%s/package.json|Using engines.node from package.json\n' "$path"
    else
        printf '%s||No version hint in .nvmrc, engines.node, or node-version input — falling back to wrangle default Node %s\n' \
            "$WRANGLE_DEFAULT_NODE" "$WRANGLE_DEFAULT_NODE"
    fi
}

# Pure function: resolves package-manager and setup-node cache config from
# the project's lockfile. Prints "<package-manager>|<cache>".
#
# The pnpm branch deliberately emits an empty cache value — see the header
# comment and issue #205.
#
# Args: <project_dir>
resolve_pm_cache() {
    local path="$1"
    if [[ -f "$path/pnpm-lock.yaml" ]]; then
        printf 'pnpm|\n'
    else
        printf 'npm|npm\n'
    fi
}

main() {
    if [[ $# -ne 2 ]]; then
        printf 'Usage: %s <path> <node-version-input>\n' "$0" >&2
        exit 1
    fi

    local input_path="$1"
    local input_node_version="$2"

    local node_line version file reason
    node_line="$(resolve_node_version "$input_node_version" "$input_path")"
    IFS='|' read -r version file reason <<<"$node_line"
    printf 'effective-version=%s\n' "$version" >> "$GITHUB_OUTPUT"
    printf 'effective-version-file=%s\n' "$file" >> "$GITHUB_OUTPUT"
    printf '%s\n' "$reason"

    local pm_line pm cache
    pm_line="$(resolve_pm_cache "$input_path")"
    IFS='|' read -r pm cache <<<"$pm_line"
    printf 'package-manager=%s\n' "$pm" >> "$GITHUB_OUTPUT"
    printf 'cache=%s\n' "$cache" >> "$GITHUB_OUTPUT"
    if [[ "$pm" == "pnpm" ]]; then
        printf 'Detected pnpm-lock.yaml; using pnpm. setup-node caching deliberately disabled (see issue #205).\n'
    else
        printf 'Detected npm lockfile; using npm with cache=npm.\n'
    fi
}

# Sourcing guard: when this file is invoked as a script, run main();
# when sourced from a test (e.g., `bash -c 'source detect_tooling.sh; \
# resolve_node_version ...'`), expose the functions without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
