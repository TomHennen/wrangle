#!/bin/bash
set -euo pipefail
set -f

# Run all tests in a container — no local tool installation required.
# Usage: ./test.sh [all|ci|quick|test|bats|lint|shellcheck|shellstyle|workflowstyle|zizmor|integration]
#
# Builds a test container with actionlint, shellcheck, ast-grep, PyYAML,
# bats-core, and zizmor, then runs the specified test suite (default: all).
#
# Targets:
#   `all`|`test`|`ci`     Full suite: lint + shellcheck + shellstyle + workflowstyle + bats + zizmor (default)
#   `quick`               Inner-loop iteration: skip zizmor for fast feedback
#   `bats`                Bats tests only
#   `lint`                actionlint only
#   `shellcheck`          ShellCheck against all *.sh and *.bats (same script CI runs)
#   `shellstyle`          wrangle-shell-lint (ast-grep WSL rules)
#   `workflowstyle`       wrangle-workflow-lint (python3 + PyYAML WWL rules)
#   `zizmor`              Zizmor workflow security linter only
#   `integration`         Non-hermetic: install real tools (network, Sigstore,
#                         osv.dev) via test/setup_integration.sh, then run the
#                         integration bats suites. Not part of `all`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="wrangle-test"
TEST_TARGET="${1:-all}"

# Validate test target. `ci` is an alias for `all` so CI configs and humans
# can use the same name. `quick` runs the inner-loop subset (no zizmor).
case "$TEST_TARGET" in
    all|test|ci|quick|bats|lint|shellcheck|shellstyle|workflowstyle|zizmor|integration) ;;
    *) printf 'Usage: %s [all|ci|quick|test|bats|lint|shellcheck|shellstyle|workflowstyle|zizmor|integration]\n' "$0" >&2; exit 1 ;;
esac

# Check Docker is available
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not running. Start Docker (or Colima) first." >&2
    exit 1
fi

# Build the test container. Locally this relies on the Docker daemon's layer
# cache (warm across runs). In CI the runner is ephemeral, so the workflow
# prebuilds the image with a GitHub Actions layer cache and sets
# WRANGLE_TEST_IMAGE_PREBUILT to have this script reuse it instead of rebuilding
# (#308).
if [[ -z "${WRANGLE_TEST_IMAGE_PREBUILT:-}" ]]; then
    echo "=== Building test container ==="
    docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/test/Dockerfile" "$SCRIPT_DIR"
fi

# Map the script-level alias to the Makefile target list. Array form so
# `quick` can pass multiple targets to one `make` invocation without
# leaning on word-splitting (and the SC2086 disable that used to require).
#
# The full suites' layers are independent, so `-j` runs them concurrently and
# `-Otarget` keeps each layer's output grouped (#530). Single-target runs skip
# the flags: there's nothing to parallelize, and integration wants live output
# rather than the buffering `-Otarget` imposes.
MAKE_FLAGS=()
case "$TEST_TARGET" in
    ci|all|test) MAKE_TARGETS=(all); MAKE_FLAGS=(-Otarget -j) ;;
    quick)       MAKE_TARGETS=(lint shellcheck shellstyle workflowstyle gotest bats); MAKE_FLAGS=(-Otarget -j) ;;
    *)           MAKE_TARGETS=("$TEST_TARGET") ;;
esac

# The repo mount is read-only, so the integration installs need a writable
# bin/metadata home. Set only for integration: unit bats exercise lib/env.sh's
# own defaults and must not see an override. ${arr[@]+...} keeps the empty
# array safe under set -u on bash 3.2 (macOS).
#
# /godata holds the Go module/build caches: the integration target compiles
# large tool graphs (cosign, osv-scanner) and the unit gotest layer fetches +
# compiles wrangle-attest's ~700MB module graph, so a cold container pays ~30s
# every run (#530). Locally a named volume warms repeat runs; in CI
# WRANGLE_GOCACHE_DIR points it at an actions/cache-managed host dir so the
# caches survive the ephemeral runner (#542). GOPATH stays at the image default
# so the go build-type's govulncheck install-cache in $GOPATH/bin is untouched.
# The suite is a test (no attested artifact), so this cross-run cache stays off
# release builds' cache-isolation surface (SPEC.md §"Cache isolation is part of
# the L3 claim"). setup_integration.sh creates $GOTMPDIR (go refuses a
# nonexistent one).
GOCACHE_MOUNT=wrangle-test-gocache
if [[ -n "${WRANGLE_GOCACHE_DIR:-}" ]]; then
    mkdir -p "$WRANGLE_GOCACHE_DIR"
    GOCACHE_MOUNT="$WRANGLE_GOCACHE_DIR"
fi
DOCKER_ENV=(-v "$GOCACHE_MOUNT":/godata)
if [[ "$TEST_TARGET" == "integration" ]]; then
    DOCKER_ENV+=(-e WRANGLE_BIN_DIR=/tmp/wrangle/bin -e WRANGLE_METADATA_DIR=/tmp/wrangle/metadata)
    DOCKER_ENV+=(-e GOPATH=/godata/gopath -e GOCACHE=/godata/gocache -e GOTMPDIR=/godata/tmp)
else
    DOCKER_ENV+=(-e GOCACHE=/godata/gocache -e GOMODCACHE=/godata/gomodcache)
fi

# Run the requested test suite
printf '=== Running: %s ===\n' "$TEST_TARGET"

docker run --rm \
    -v "$SCRIPT_DIR":/wrangle:ro \
    -w /wrangle \
    ${DOCKER_ENV[@]+"${DOCKER_ENV[@]}"} \
    "$IMAGE_NAME" \
    make ${MAKE_FLAGS[@]+"${MAKE_FLAGS[@]}"} "${MAKE_TARGETS[@]}"
