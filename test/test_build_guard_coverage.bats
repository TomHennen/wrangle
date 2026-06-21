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
    # invoke the guard, named by their path under build/actions (e.g.
    # `npm`, `go/checks`). Composites belong here only if they run NO
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
    count=$(find "$REPO_ROOT/build/actions" \
        -name action.yml -type f | wc -l)
    [[ "$count" -gt 0 ]]
}

@test "build-guard-coverage: every build composite references the stop-commands guard" {
    # Enumerate every action.yml under build/actions at any depth (flat
    # build types live at build/actions/<type>/action.yml; go nests two
    # composites at build/actions/go/<phase>/action.yml). For each
    # non-exempt composite, the composite MUST reference
    # lib/stop_commands_guard.sh at least once — either directly in
    # action.yml or in a script it delegates to (the action.yml -> script
    # extraction pattern CLAUDE.md requires for any run: block with
    # logic). New composites added without wiring in the guard fail here —
    # the test does not need to be updated for new build types, only for
    # new exemptions (which require updating the EXEMPT_COMPOSITES
    # allowlist above with a rationale).
    local missing=()
    while IFS= read -r -d '' action_yml; do
        local composite_dir composite_name
        composite_dir="$(dirname "$action_yml")"
        composite_name="${action_yml#"$REPO_ROOT"/build/actions/}"
        composite_name="${composite_name%/action.yml}"

        if is_exempt "$composite_name"; then
            continue
        fi

        # Search the whole composite directory: action.yml plus any sibling
        # scripts it shells out to. The per-composite test.bats (asserted by
        # the next test) is what pins the guard to the actual tool
        # invocation rather than an inert reference.
        if ! grep -rqF "$GUARD" "$composite_dir"; then
            missing+=("$composite_name")
        fi
    done < <(find "$REPO_ROOT/build/actions" \
        -name action.yml -type f -print0 | sort -z)

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
    # inert). The build type's test.bats MUST reference the literal
    # helper filename `stop_commands_guard.sh` — which is what an
    # actual assertion grep'ing the action.yml looks like, not what
    # pure prose would say. A maintainer dropping the assertion and
    # leaving a section-header comment that reads "stop-commands guard"
    # alone does NOT satisfy this check.
    #
    # A build type may keep one shared test.bats covering several nested
    # composites (go/checks and go/build share build/actions/go/test.bats,
    # which pins both the `run` wrap and the begin/end wrap), so search the
    # type's whole tree for a *.bats that references the helper, not just
    # the composite's own directory.
    local missing=()
    while IFS= read -r -d '' action_yml; do
        local composite_name type_name type_root
        composite_name="${action_yml#"$REPO_ROOT"/build/actions/}"
        composite_name="${composite_name%/action.yml}"
        type_name="${composite_name%%/*}"
        type_root="$REPO_ROOT/build/actions/$type_name"

        if is_exempt "$composite_name"; then
            continue
        fi
        if ! grep -rqF --include='*.bats' 'stop_commands_guard.sh' "$type_root"; then
            missing+=("$composite_name (no guard assertion in $type_name/*.bats)")
        fi
    done < <(find "$REPO_ROOT/build/actions" \
        -name action.yml -type f -print0 | sort -z)

    if (( ${#missing[@]} > 0 )); then
        printf 'Build composite test.bats missing guard-coverage assertion: %s\n' \
            "${missing[*]}" >&2
        return 1
    fi
}
