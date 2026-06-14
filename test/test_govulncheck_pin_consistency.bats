#!/usr/bin/env bats

# Divergence guard for the govulncheck version, which lives in two places with
# no shared source: test/Dockerfile's GOVULNCHECK_VERSION (what the unit suite
# installs and exercises) and the govulncheck-version default in
# build/actions/go/checks/action.yml (what adopters' builds run). The Dockerfile
# comment asserts they match; this fails closed when they don't, so the version
# the tests prove out can't drift from the one wrangle ships.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
}

@test "govulncheck version agrees between test/Dockerfile and the go checks action default" {
    cd "$REPO_ROOT"

    local dockerfile_version action_version
    dockerfile_version="$(grep -E '^ARG GOVULNCHECK_VERSION=' test/Dockerfile \
        | head -1 | sed -E 's/.*=(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    # The default: line belonging to the govulncheck-version input; awk scopes to
    # that block so a sibling input's default (e.g. gofmt's) can't be picked up.
    action_version="$(awk '/^  govulncheck-version:/{f=1} f && /default:/{print; exit}' \
        build/actions/go/checks/action.yml \
        | sed -E 's/.*"(v[0-9]+\.[0-9]+\.[0-9]+)".*/\1/')"

    [ -n "$dockerfile_version" ]  # guard against the extraction silently matching nothing
    [ -n "$action_version" ]

    if [ "$dockerfile_version" != "$action_version" ]; then
        printf 'govulncheck version drift: test/Dockerfile=%s, go checks action default=%s\n' \
            "$dockerfile_version" "$action_version" >&2
        return 1
    fi
}
