#!/usr/bin/env bats

# Meta-test: the publish trigger and the Dockerfiles must agree.
#
# `publish tool images` rebuilds the curated tool images on a narrow `paths:`
# filter. If a Dockerfile grows an input the filter does not match, the image
# silently goes stale on the next change to it while CI stays green — the
# supply-chain failure wrangle exists to prevent. test/check_publish_trigger.py
# derives the real input set from each Dockerfile and fails if the filter misses
# one, so a new COPY cannot be landed without extending the trigger.
#
# The reverse direction (the filter matching more than the Dockerfiles read) is
# safe and deliberately allowed — see the canary test for the floor it must not
# fall back through.

load "lib/bats_helpers"

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    CHECK="$REPO_ROOT/test/check_publish_trigger.py"

    # PyYAML lives in the managed venv the test image builds; fall back to a
    # system python3 that has it (local dev). Same resolution as
    # tools/wrangle-workflow-lint/lint.sh.
    if [[ -x /opt/wrangle-workflow-lint/bin/python3 ]]; then
        PYTHON=/opt/wrangle-workflow-lint/bin/python3
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
        PYTHON=python3
    else
        skip_or_fail "no python3 with PyYAML on PATH"
    fi
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/publish-trigger-XXXXXX")"
}

teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

@test "publish-trigger: every Dockerfile build input is matched by the trigger" {
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT"
    [ "$status" -eq 0 ]
    # Guard against a vacuous pass: all five curated images, each contributing
    # inputs. A parse that silently found nothing would still "cover" the set.
    [[ "$output" == *"across 5 images"* ]]
    local checked="${output#checked }"
    [[ "${checked%% *}" -ge 5 ]]
}

@test "publish-trigger: the check fails when the trigger misses a build input" {
    # The check's own red path: the same matrix against a filter that omits
    # everything under tools/ must be rejected.
    cat > "$TMP_DIR/incomplete.yml" <<'YAML'
on:
  push:
    paths:
      - lib/**
jobs:
  publish:
    uses: ./.github/workflows/build_and_publish_container.yml
    strategy:
      matrix:
        include:
          - path: tools/osv
    with:
      dockerfile: ${{ matrix.path }}/Dockerfile
YAML
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT" --workflow "$TMP_DIR/incomplete.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"tools/osv/Dockerfile"* ]]
    [[ "$output" == *"tools/osv/adapter.sh"* ]]
}

# A stand-in publish workflow building $TMP_DIR/tools/faketool, whose Dockerfile
# is the given body. Its trigger matches everything under tools/, so only a build
# input the check cannot see at all can keep it green.
fake_image() {
    mkdir -p "$TMP_DIR/tools/faketool"
    cat > "$TMP_DIR/tools/faketool/Dockerfile"
    cat > "$TMP_DIR/fake.yml" <<'YAML'
on:
  push:
    paths:
      - tools/**
jobs:
  publish:
    uses: ./.github/workflows/build_and_publish_container.yml
    strategy:
      matrix:
        include:
          - path: tools/faketool
    with:
      dockerfile: ${{ matrix.path }}/Dockerfile
YAML
    printf '%s' "$TMP_DIR/fake.yml"
}

@test "publish-trigger: a Dockerfile that bind-mounts the context fails the check" {
    # A bind mount reads the build context with no COPY to derive an input set
    # from, so the check refuses it rather than reporting a coverage it can't see.
    local workflow
    workflow="$(fake_image <<'DOCKERFILE'
FROM scratch
RUN --mount=type=bind,source=tools,target=/src true
DOCKERFILE
)"
    run "$PYTHON" "$CHECK" --repo-root "$TMP_DIR" --workflow "$workflow"
    [ "$status" -eq 2 ]
    [[ "$output" == *"bind-mounts the build context"* ]]
}

@test "publish-trigger: a stage mount does not mask a context bind mount on the same line" {
    local workflow
    workflow="$(fake_image <<'DOCKERFILE'
FROM scratch AS build
FROM scratch
RUN --mount=type=cache,target=/c --mount=type=bind,from=build,source=/out,target=/s --mount=type=bind,source=lib,target=/l true
DOCKERFILE
)"
    run "$PYTHON" "$CHECK" --repo-root "$TMP_DIR" --workflow "$workflow"
    [ "$status" -eq 2 ]
    [[ "$output" == *"bind-mounts the build context"* ]]
}

@test "publish-trigger: an ONBUILD copy fails the check" {
    local workflow
    workflow="$(fake_image <<'DOCKERFILE'
FROM scratch
ONBUILD COPY tools/catalog.json /catalog.json
DOCKERFILE
)"
    run "$PYTHON" "$CHECK" --repo-root "$TMP_DIR" --workflow "$workflow"
    [ "$status" -eq 2 ]
    [[ "$output" == *"ONBUILD"* ]]
}

@test "publish-trigger: an image built outside the publish job is still checked" {
    # Enrolling an image is documented as a matrix line, but a second job calling
    # the image builder must not slip past the check.
    mkdir -p "$TMP_DIR/tools/faketool"
    printf 'FROM scratch\nCOPY tools/catalog.json /catalog.json\n' \
        > "$TMP_DIR/tools/faketool/Dockerfile"
    printf '{}\n' > "$TMP_DIR/tools/catalog.json"
    cat > "$TMP_DIR/second.yml" <<'YAML'
on:
  push:
    paths:
      - lib/**
jobs:
  publish-more:
    uses: ./.github/workflows/build_and_publish_container.yml
    strategy:
      matrix:
        include:
          - path: tools/faketool
    with:
      dockerfile: ${{ matrix.path }}/Dockerfile
YAML
    run "$PYTHON" "$CHECK" --repo-root "$TMP_DIR" --workflow "$TMP_DIR/second.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"tools/catalog.json"* ]]
}

@test "publish-trigger: the gate's ** covers a path at the root of its tree" {
    # git's :(glob) ** stands in for zero directories where GitHub's does not, so
    # a tools/*.go the gate diffs must still be one the trigger rebuilds.
    mkdir -p "$TMP_DIR/tools/faketool"
    printf 'FROM scratch\nCOPY tools/faketool/adapter.sh /adapter.sh\n' \
        > "$TMP_DIR/tools/faketool/Dockerfile"
    printf '#!/bin/bash\n' > "$TMP_DIR/tools/faketool/adapter.sh"
    printf 'package main\n' > "$TMP_DIR/tools/toplevel.go"
    cat > "$TMP_DIR/rootgo.yml" <<'YAML'
on:
  push:
    paths:
      - tools/*/Dockerfile
      - tools/*/adapter.sh
      - "tools/**/*.go"
jobs:
  publish:
    uses: ./.github/workflows/build_and_publish_container.yml
    strategy:
      matrix:
        include:
          - path: tools/faketool
    with:
      dockerfile: ${{ matrix.path }}/Dockerfile
YAML
    local gate
    gate="$(gate_script_with "':(glob)tools/*/Dockerfile'" "':(glob)tools/*/adapter.sh'" \
        "':(glob)tools/**/*.go'")"
    run "$PYTHON" "$CHECK" --repo-root "$TMP_DIR" --workflow "$TMP_DIR/rootgo.yml" \
        --check-gate --gate-script "$gate"
    [ "$status" -eq 1 ]
    [[ "$output" == *"tools/toplevel.go"* ]]
}

@test "publish-trigger: dev scripts and the catalog do not trigger a rebuild" {
    # The floor the narrowing must not fall back through: files in no image's
    # build context. A catalog-only push is a digest bump — matching it would
    # loop the post-publish auto-bump.
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT" --match \
        tools/catalog.json \
        tools/cut_release.sh \
        tools/open_catalog_bump_pr.sh \
        tools/bump_version_refs.sh \
        tools/check_catalog.sh \
        tools/gen_policies/gen.sh \
        tools/dependency-review/action.yml \
        tools/scorecard/action.yml
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        [[ "$line" == NO-MATCH* ]] || { printf 'unexpectedly triggers a rebuild: %s\n' "$line" >&2; return 1; }
    done <<< "$output"
}

# A stand-in release gate whose stale-image diff-set is the given pathspecs.
gate_script_with() {
    printf 'PROVENANCE_DIFF_PATHS=(\n' > "$TMP_DIR/gate.sh"
    printf '    %s\n' "$@" >> "$TMP_DIR/gate.sh"
    printf ')\n' >> "$TMP_DIR/gate.sh"
    printf '%s' "$TMP_DIR/gate.sh"
}

@test "publish-trigger: the release gate's stale-image diff-set agrees with the trigger" {
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT" --check-gate
    [ "$status" -eq 0 ]
}

@test "publish-trigger: the check fails when the release gate misses a build input" {
    # A build input the gate does not diff is an image it calls fresh with its
    # source changed under it.
    local gate
    gate="$(gate_script_with "':(glob)tools/*/Dockerfile'")"
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT" --check-gate --gate-script "$gate"
    [ "$status" -eq 1 ]
    [[ "$output" == *"lib/sarif_adapter_exit.sh"* ]]
}

@test "publish-trigger: the check fails when the release gate flags what the trigger ignores" {
    # The other direction: a path the gate diffs but the trigger ignores reds the
    # release gate with no rebuild able to clear it.
    local gate
    gate="$(gate_script_with tools lib)"
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT" --check-gate --gate-script "$gate"
    [ "$status" -eq 1 ]
    [[ "$output" == *"tools/cut_release.sh"* ]]
}

@test "publish-trigger: an image's own inputs do trigger a rebuild" {
    # The opposite floor — the matcher is not vacuously rejecting everything.
    run "$PYTHON" "$CHECK" --repo-root "$REPO_ROOT" --match \
        tools/osv/Dockerfile \
        tools/osv/adapter.sh \
        tools/syft/install.sh \
        tools/zizmor/requirements.txt \
        tools/wrangle-lint/main.go \
        tools/wrangle-attest/sign.go \
        tools/go.mod \
        tools/go.sum \
        lib/sarif_adapter_exit.sh
    [ "$status" -eq 0 ]
    [[ "$output" != *NO-MATCH* ]]
}
