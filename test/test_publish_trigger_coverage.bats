#!/usr/bin/env bats

# Meta-test: the tool-image publish trigger, the Dockerfiles, and the release
# gate's stale-image diff-set must agree.
#
# `publish tool images` rebuilds the curated images on a narrow `paths:` filter.
# If a Dockerfile grows an input the filter does not match, the image silently
# goes stale on the next change to it while CI stays green — the supply-chain
# failure wrangle exists to prevent. test/check_publish_trigger.py derives the
# real input set from each Dockerfile and fails if the filter or the release
# gate misses one, so a new COPY cannot land without extending both.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    CHECK="$REPO_ROOT/test/check_publish_trigger.py"

    # Mirror lint.sh's interpreter discovery: the managed venv the test image
    # builds, or a system python3 with PyYAML for local dev. The check is
    # mandatory in CI, so a missing interpreter fails loud rather than skips.
    if [[ -x /opt/wrangle-workflow-lint/bin/python3 ]]; then
        PYTHON=/opt/wrangle-workflow-lint/bin/python3
    elif command -v python3 >/dev/null 2>&1; then
        PYTHON=python3
    else
        printf 'python3 not on PATH — run via ./test.sh (the Docker image provides it)\n' >&2
        return 1
    fi
    if ! "$PYTHON" -c 'import yaml' >/dev/null 2>&1; then
        printf 'PyYAML not importable — install tools/wrangle-workflow-lint/requirements.txt into a venv (see test/Dockerfile)\n' >&2
        return 1
    fi
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/publish-trigger-XXXXXX")"
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

# fake_repo — a stand-in repo root holding one image, tools/faketool, whose
# Dockerfile is read from stdin.
fake_repo() {
    mkdir -p "$TMP_DIR/tools/faketool"
    printf '#!/bin/bash\n' > "$TMP_DIR/tools/faketool/adapter.sh"
    cat > "$TMP_DIR/tools/faketool/Dockerfile"
}

# fake_workflow <file> <job> <trigger-path>... — a stand-in publish workflow at
# .github/workflows/<file> whose <job> builds tools/faketool on those paths.
fake_workflow() {
    local file="$1" job="$2"
    shift 2
    mkdir -p "$TMP_DIR/.github/workflows"
    {
        printf 'on:\n  push:\n    paths:\n'
        printf '      - %s\n' "$@"
        printf 'jobs:\n  %s:\n' "$job"
        printf '    uses: ./.github/workflows/build_and_publish_container.yml\n'
        printf '    strategy:\n      matrix:\n        include:\n          - path: tools/faketool\n'
        printf '    with:\n      dockerfile: ${{ matrix.path }}/Dockerfile\n'
    } > "$TMP_DIR/.github/workflows/$file"
}

# gate_script_with <pathspec>... — a stand-in release gate diffing those paths.
gate_script_with() {
    {
        printf 'PROVENANCE_DIFF_PATHS=(\n'
        printf '    %s\n' "$@"
        printf ')\n'
    } > "$TMP_DIR/gate.sh"
}

run_check() {
    run "$PYTHON" "$CHECK" --repo-root "$TMP_DIR" \
        --workflow .github/workflows/publish.yml --gate-script "$TMP_DIR/gate.sh"
}

@test "publish-trigger: every image build input is matched by the trigger and the release gate" {
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT"
    [ "$status" -eq 0 ]
    # Guard against a vacuous pass: a parse that silently found nothing would
    # still "cover" the set.
    local images="${output##*across }"
    [[ "${images%% *}" -ge 5 ]]
    local inputs="${output#checked }"
    [[ "${inputs%% *}" -ge 20 ]]
}

@test "publish-trigger: an input the trigger does not match fails the check" {
    fake_repo <<'DOCKERFILE'
FROM scratch
COPY tools/faketool/adapter.sh /adapter.sh
DOCKERFILE
    fake_workflow publish.yml publish tools/faketool/Dockerfile
    gate_script_with tools/faketool/Dockerfile
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"tools/faketool/adapter.sh"* ]]
}

@test "publish-trigger: a release gate that diffs less than the trigger fails the check" {
    # A build input the gate does not diff is an image it calls fresh with its
    # source changed under it.
    fake_repo <<'DOCKERFILE'
FROM scratch
COPY tools/faketool/adapter.sh /adapter.sh
DOCKERFILE
    fake_workflow publish.yml publish tools/faketool/Dockerfile tools/faketool/adapter.sh
    gate_script_with tools/faketool/Dockerfile
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"call an image fresh with its source changed"* ]]
    [[ "$output" == *"tools/faketool/adapter.sh"* ]]
}

@test "publish-trigger: a release gate that diffs more than the trigger fails the check" {
    # The other direction: a path the gate diffs but the trigger ignores reds the
    # release with no rebuild able to clear it.
    fake_repo <<'DOCKERFILE'
FROM scratch
COPY tools/faketool/adapter.sh /adapter.sh
DOCKERFILE
    fake_workflow publish.yml publish tools/faketool/Dockerfile tools/faketool/adapter.sh
    gate_script_with tools/faketool/Dockerfile tools/faketool/adapter.sh lib
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"no rebuild able to clear it"* ]]
    [[ "$output" == *lib* ]]
}

@test "publish-trigger: an image built outside the publish job is still checked" {
    # Enrolling an image is documented as a matrix line, but a second job calling
    # the image builder must not slip past the check.
    fake_repo <<'DOCKERFILE'
FROM scratch
COPY tools/faketool/adapter.sh /adapter.sh
DOCKERFILE
    fake_workflow publish.yml publish-more tools/faketool/Dockerfile
    gate_script_with tools/faketool/Dockerfile
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"tools/faketool/adapter.sh"* ]]
}

@test "publish-trigger: a second workflow that builds images fails the check" {
    # Only the checked workflow's trigger is proven, so another workflow building
    # images would publish from a filter nothing holds to its Dockerfiles.
    fake_repo <<'DOCKERFILE'
FROM scratch
COPY tools/faketool/adapter.sh /adapter.sh
DOCKERFILE
    fake_workflow publish.yml publish tools/faketool/Dockerfile tools/faketool/adapter.sh
    fake_workflow extra.yml publish-extra tools/faketool/Dockerfile
    gate_script_with tools/faketool/Dockerfile tools/faketool/adapter.sh
    run_check
    [ "$status" -eq 2 ]
    [[ "$output" == *"extra.yml"* ]]
}

@test "publish-trigger: a build context this check cannot model fails closed" {
    # Each of these reads the build context without a COPY the check can expand
    # into an input set, so it refuses rather than reporting a coverage it can't
    # see. The second hides a context bind mount behind a stage mount.
    local body
    for body in \
        'RUN --mount=type=bind,source=tools,target=/src true' \
        'RUN --mount=type=bind,from=build,source=/out,target=/s --mount=type=bind,source=lib,target=/l true' \
        'ONBUILD COPY tools/faketool/adapter.sh /adapter.sh' \
        'COPY tools/faketool/*.sh /'
    do
        printf 'FROM scratch AS build\nFROM scratch\n%s\n' "$body" | fake_repo
        fake_workflow publish.yml publish 'tools/**'
        gate_script_with tools
        run_check
        [ "$status" -eq 2 ]
    done
}

@test "publish-trigger: dev scripts and the catalog do not trigger a rebuild" {
    # The floor the narrowing must not fall back through: files in no image's
    # build context. A catalog-only push is a digest bump — matching it would
    # loop the post-publish auto-bump.
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT" --match \
        tools/catalog.json \
        tools/osv-scanner.toml \
        tools/cut_release.sh \
        tools/open_catalog_bump_pr.sh \
        tools/bump_version_refs.sh \
        tools/check_catalog.sh \
        tools/gen_policies/gen.sh \
        tools/wrangle-shell-lint/requirements.txt \
        tools/wrangle-workflow-lint/lint.py \
        tools/dependency-review/action.yml \
        tools/scorecard/action.yml \
        lib/registry.sh
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        [[ "$line" == NO-MATCH* ]] || {
            printf 'unexpectedly triggers a rebuild: %s\n' "$line" >&2
            return 1
        }
    done <<< "$output"
}

@test "publish-trigger: inputs outside the build context still trigger a rebuild" {
    # These change an image without appearing in any COPY, so no Dockerfile can
    # reveal them and only this list keeps them covered.
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT" --match \
        .dockerignore \
        .github/workflows/build_and_publish_container.yml \
        build/actions/container/action.yml \
        build/actions/container/resolve_cache.sh
    [ "$status" -eq 0 ]
    [[ "$output" != *NO-MATCH* ]]
}
