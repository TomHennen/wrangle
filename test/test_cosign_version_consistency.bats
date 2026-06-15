#!/usr/bin/env bats

# Divergence guard for the cosign version. wrangle's unit/integration suites
# exercise the cosign built from tools/go.mod, while the publish workflows
# install cosign via sigstore/cosign-installer. If the installer's cosign and
# go.mod's cosign drift, a flag/output change can pass the suite against one
# version and break a real release on another. This pins every cosign-installer
# step's cosign-release to go.mod's version and fails closed when they diverge.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
}

@test "every cosign-installer step pins cosign-release to the cosign in tools/go.mod" {
    cd "$REPO_ROOT"

    local gomod_ver
    gomod_ver="$(grep -E 'github.com/sigstore/cosign/v[0-9]+ v[0-9]' tools/go.mod \
        | head -1 | sed -E 's#.* (v[0-9]+\.[0-9]+\.[0-9]+).*#\1#')"
    [ -n "$gomod_ver" ]  # guard against the extraction silently matching nothing

    # Count cosign-installer steps vs. cosign-release pins matching go.mod across
    # wrangle's own trees (gh_workflow_examples are adopter samples, excluded).
    # Equal-and-nonzero means every installer is pinned to the tested version;
    # a new installer without the pin, or a mismatched/stale pin, drops a match.
    local installers matches
    installers="$(grep -rhE --include='*.yml' --include='*.yaml' --exclude-dir=fixtures \
        'uses:[[:space:]]*sigstore/cosign-installer@' .github/workflows build actions | wc -l | tr -d ' ')"
    matches="$(grep -rhE --include='*.yml' --include='*.yaml' --exclude-dir=fixtures \
        "cosign-release:[[:space:]]*${gomod_ver}\$" .github/workflows build actions | wc -l | tr -d ' ')"

    [ "$installers" -gt 0 ]
    if [ "$installers" -ne "$matches" ]; then
        printf 'cosign drift: %s cosign-installer step(s), %s pinned to go.mod cosign %s\n' \
            "$installers" "$matches" "$gomod_ver" >&2
        return 1
    fi
}
