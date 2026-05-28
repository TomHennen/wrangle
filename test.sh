#!/bin/bash
set -euo pipefail
set -f

# Run all tests in a container — no local tool installation required.
# Usage: ./test.sh [all|ci|quick|test|bats|lint|shellcheck|zizmor]
#
# Builds a test container with actionlint, shellcheck, bats-core, and
# zizmor, then runs the specified test suite (default: all).
#
# Targets:
#   `all`|`test`|`ci`     Full suite: lint + shellcheck + bats + zizmor (default)
#   `quick`               Inner-loop iteration: lint + shellcheck + bats (skip zizmor)
#   `bats`                Bats tests only
#   `lint`                actionlint only
#   `shellcheck`          ShellCheck against all *.sh
#   `zizmor`              Zizmor workflow security linter only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="wrangle-test"
TEST_TARGET="${1:-all}"

# Validate test target. `ci` is an alias for `all` so CI configs and humans
# can use the same name. `quick` runs the inner-loop subset (no zizmor).
case "$TEST_TARGET" in
    all|test|ci|quick|bats|lint|shellcheck|zizmor) ;;
    *) echo "Usage: $0 [all|ci|quick|test|bats|lint|shellcheck|zizmor]" >&2; exit 1 ;;
esac

# Check Docker is available
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not running. Start Docker (or Colima) first." >&2
    exit 1
fi

# Build the test container (cached after first run)
echo "=== Building test container ==="
docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/test/Dockerfile" "$SCRIPT_DIR"

# Map the script-level alias to the Makefile target list. Array form so
# `quick` can pass multiple targets to one `make` invocation without
# leaning on word-splitting (and the SC2086 disable that used to require).
case "$TEST_TARGET" in
    ci)    MAKE_TARGETS=(all) ;;
    quick) MAKE_TARGETS=(lint shellcheck bats) ;;
    *)     MAKE_TARGETS=("$TEST_TARGET") ;;
esac

# Run the requested test suite
echo "=== Running: $TEST_TARGET ==="

docker run --rm \
    -v "$SCRIPT_DIR":/wrangle:ro \
    -w /wrangle \
    "$IMAGE_NAME" \
    make "${MAKE_TARGETS[@]}"
