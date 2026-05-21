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
# The decision functions (`detect_pm`, `has_build_script`,
# `has_real_test_script`, `find_one_tarball`) are split out so test.bats
# can exercise the branches as pure args-in → stdout-out functions, no
# npm/pnpm shim required. The main() function glues them to the install/
# build/test/pack invocations against real npm/pnpm — that integration
# strand still needs shimming, but the decision logic does not.
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

# Pure function: detects which package manager to use, based on the
# project's lockfile. validate_inputs.sh has already ensured exactly one
# supported lockfile is present.
#
# Args: <project_dir>
# Prints: "npm" or "pnpm"
detect_pm() {
    local path="$1"
    if [[ -f "$path/pnpm-lock.yaml" ]]; then
        printf 'pnpm\n'
    else
        printf 'npm\n'
    fi
}

# Pure function: returns 0 if package.json declares a `build` script.
# Null-safe against `"scripts": null` or a missing `scripts` field.
#
# Args: <project_dir>
has_build_script() {
    local path="$1"
    [[ "$(jq -r '(.scripts // {}) | has("build")' "$path/package.json")" == "true" ]]
}

# Pure function: returns 0 if package.json declares a `test` script AND
# that script is not the npm-default `no test specified` stub. Substring
# match against the default phrase so minor wording tweaks in future
# npm/pnpm releases don't accidentally re-enable the no-op.
#
# Args: <project_dir>
has_real_test_script() {
    local path="$1"
    local has_test test_cmd
    has_test="$(jq -r '(.scripts // {}) | has("test")' "$path/package.json")"
    [[ "$has_test" == "true" ]] || return 1
    test_cmd="$(jq -r '.scripts.test // ""' "$path/package.json")"
    [[ "$test_cmd" != *'no test specified'* ]]
}

# Pure function: asserts exactly one *.tgz tarball exists in $1/dist/
# and prints its filename (without the dist/ prefix). Exits non-zero
# if the count is anything other than 1.
#
# nullglob makes `*.tgz` expand to nothing rather than the literal
# pattern when dist/ is empty, so the count check works in both cases.
# The filename printf is the only place an attacker-controlled name
# could enter the step log; main() ensures this runs inside the
# stop_commands_guard.sh wrap, so a hostile `::add-mask::evil.tgz`
# planted by a postinstall hook cannot inject workflow commands.
#
# Args: <project_dir>
find_one_tarball() {
    local path="$1"
    local tarballs
    (
        cd "$path"
        shopt -s nullglob
        tarballs=(dist/*.tgz)
        if (( ${#tarballs[@]} != 1 )); then
            printf 'Error: expected exactly 1 tarball in dist/, found %d:\n' "${#tarballs[@]}" >&2
            printf '  %s\n' "${tarballs[@]}" >&2
            exit 1
        fi
        # Strip the dist/ prefix so the output matches the action.yml's
        # previous `cd "$INPUT_PATH/dist"; tarball=*.tgz` contract —
        # downstream steps (hash, SBOM, attach) expect a bare filename
        # relative to dist/.
        printf '%s\n' "${tarballs[0]#dist/}"
    )
}

main() {
    if [[ $# -ne 3 ]]; then
        printf 'Usage: %s <path> <run_tests> <ignore_scripts>\n' "$0" >&2
        exit 1
    fi

    local input_path="$1"
    local run_tests="$2"
    local ignore_scripts="$3"

    local pm
    pm="$(detect_pm "$input_path")"
    printf 'Package manager: %s\n' "$pm"

    cd "$input_path"

    local -a ignore_scripts_args=()
    if [[ "$ignore_scripts" == "true" ]]; then
        ignore_scripts_args=(--ignore-scripts)
        printf 'ignore-scripts=true: all package.json scripts will be skipped\n'
    fi

    if [[ "$pm" == "pnpm" ]]; then
        printf 'Installing dependencies (pnpm install --frozen-lockfile)...\n'
        pnpm install --frozen-lockfile "${ignore_scripts_args[@]}"
    else
        printf 'Installing dependencies (npm ci)...\n'
        npm ci "${ignore_scripts_args[@]}"
    fi

    if [[ "$ignore_scripts" == "true" ]]; then
        printf 'Skipping %s run build and %s test (ignore-scripts=true)\n' "$pm" "$pm"
    else
        if has_build_script "$input_path"; then
            printf 'Running %s run build...\n' "$pm"
            "$pm" run build
        else
            printf 'No build script in package.json — skipping build step\n'
        fi

        if [[ "$run_tests" == "true" ]]; then
            if has_real_test_script "$input_path"; then
                printf 'Running %s test...\n' "$pm"
                "$pm" test
            else
                printf 'No non-default test script in package.json — skipping tests\n'
            fi
        fi
    fi

    printf 'Packing tarball into dist/ (%s pack)...\n' "$pm"
    mkdir -p dist
    # `<pm> pack --pack-destination dist` writes the tarball to dist/.
    # --ignore-scripts (when set) suppresses prepack/postpack/prepare on
    # the pack side too for both npm and pnpm.
    "$pm" pack --pack-destination dist "${ignore_scripts_args[@]}"

    local tarball
    tarball="$(find_one_tarball "$input_path")"

    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        # File-based output (not the ::set-output:: stdout command), so this
        # write is unaffected by the stop-commands suspension.
        printf 'tarball=%s\n' "$tarball" >> "$GITHUB_OUTPUT"
    fi
}

# Sourcing guard: tests source this file to call detect_pm,
# has_build_script, has_real_test_script, and find_one_tarball directly
# without running the install/build/test/pack pipeline.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
