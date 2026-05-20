#!/usr/bin/env bats

# Meta-test: every wrangle build composite MUST run its ecosystem build
# tooling (compile, install, test, lint) under lib/stop_commands_guard.sh.
#
# Why this lives at the top of test/ and not inside one of the per-tool
# build/actions/*/test.bats files: those per-tool tests only catch
# regressions in the composites that EXIST today. A new build composite
# added in a future PR (build/actions/go/, build/actions/rust/, ...)
# could ship without ever referencing the guard and every per-tool test
# would still pass — the workflow-command-injection hole would slip
# through silently. This meta-test enumerates the directory and fails
# if a new composite is added without wiring in the guard.
#
# See docs/SLSA_L3_AUDIT.md Finding 3 and docs/SPEC.md "Workflow-command-
# injection guard for build composites".

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    GUARD="lib/stop_commands_guard.sh"

    # Explicit allowlist of composites that intentionally do NOT need to
    # invoke the guard. Composites belong here only if they run NO
    # caller-controlled code, NO ecosystem tooling against caller-
    # controlled inputs, AND echo nothing derived from caller inputs to
    # the step log. Today the list is empty — every existing build
    # composite runs adversarially-influenceable output through the step
    # log (Dockerfiles, package.json hooks, pytest, shellcheck source
    # excerpts, bats test code). Add a composite here ONLY with a
    # written rationale in the comment justifying the exemption.
    EXEMPT_COMPOSITES=()
}

is_exempt() {
    local name="$1"
    for exempt in "${EXEMPT_COMPOSITES[@]}"; do
        [[ "$name" == "$exempt" ]] && return 0
    done
    return 1
}

@test "build-guard-coverage: at least one build composite exists" {
    # Sanity check — if this fails the enumeration below is meaningless.
    local count
    count=$(find "$REPO_ROOT/build/actions" -mindepth 2 -maxdepth 2 \
        -name action.yml -type f | wc -l)
    [[ "$count" -gt 0 ]]
}

@test "build-guard-coverage: every build composite references the stop-commands guard" {
    # Enumerate build/actions/<name>/action.yml. For each non-exempt
    # composite, the action.yml MUST reference lib/stop_commands_guard.sh
    # at least once. New composites added without wiring in the guard
    # fail here — the test does not need to be updated for new build
    # types, only for new exemptions (which require updating the
    # EXEMPT_COMPOSITES allowlist above with a rationale).
    local missing=()
    while IFS= read -r -d '' action_yml; do
        local composite_dir composite_name
        composite_dir="$(dirname "$action_yml")"
        composite_name="$(basename "$composite_dir")"

        if is_exempt "$composite_name"; then
            continue
        fi

        if ! grep -qF "$GUARD" "$action_yml"; then
            missing+=("$composite_name")
        fi
    done < <(find "$REPO_ROOT/build/actions" -mindepth 2 -maxdepth 2 \
        -name action.yml -type f -print0)

    if (( ${#missing[@]} > 0 )); then
        printf 'Build composites missing stop_commands_guard.sh reference: %s\n' \
            "${missing[*]}" >&2
        printf 'Either wire in lib/stop_commands_guard.sh (see existing\n' >&2
        printf 'composites for the pattern) or add the composite to\n' >&2
        printf 'EXEMPT_COMPOSITES in %s with a written rationale.\n' \
            "$BATS_TEST_FILENAME" >&2
        return 1
    fi
}

@test "build-guard-coverage: every build composite test.bats pins guard coverage" {
    # A per-composite assertion that its action.yml actually wraps the
    # ecosystem invocation (not just imports the helper somewhere
    # inert). Each composite's test.bats MUST mention the guard at
    # least once, so a future maintainer who silently drops the wrap
    # but leaves an import comment behind still trips a test.
    local missing=()
    while IFS= read -r -d '' action_yml; do
        local composite_dir composite_name test_bats
        composite_dir="$(dirname "$action_yml")"
        composite_name="$(basename "$composite_dir")"
        test_bats="$composite_dir/test.bats"

        if is_exempt "$composite_name"; then
            continue
        fi
        if [[ ! -f "$test_bats" ]]; then
            missing+=("$composite_name (no test.bats)")
            continue
        fi
        if ! grep -qE 'stop_commands_guard|stop-commands guard' "$test_bats"; then
            missing+=("$composite_name")
        fi
    done < <(find "$REPO_ROOT/build/actions" -mindepth 2 -maxdepth 2 \
        -name action.yml -type f -print0)

    if (( ${#missing[@]} > 0 )); then
        printf 'Build composite test.bats missing guard-coverage assertion: %s\n' \
            "${missing[*]}" >&2
        return 1
    fi
}
