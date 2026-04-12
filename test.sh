#!/bin/bash
set -euo pipefail

# Run all tests in a container — no local tool installation required.
# Usage: ./test.sh [bats|lint|shellcheck|all]
#
# Builds a test container with actionlint, shellcheck, and bats-core,
# then runs the specified test suite (default: all).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="wrangle-test"
TEST_TARGET="${1:-all}"

# Validate test target
case "$TEST_TARGET" in
    all|test|bats|lint|shellcheck|test-actions) ;;
    *) echo "Usage: $0 [all|test|bats|lint|shellcheck|test-actions]" >&2; exit 1 ;;
esac

# Check Docker is available
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not running. Start Docker (or Colima) first." >&2
    exit 1
fi

# Build the test container (cached after first run)
echo "=== Building test container ==="
docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/test/Dockerfile" "$SCRIPT_DIR"

# Run the requested test suite
echo "=== Running: $TEST_TARGET ==="

run_container_tests() {
    docker run --rm \
        -v "$SCRIPT_DIR":/wrangle:ro \
        -w /wrangle \
        "$IMAGE_NAME" \
        make "$1"
}

run_act_tests() {
    # act-based tests run on the host (act needs Docker to spawn runner containers).
    # The Docker test container cannot use act because act bind-mounts the workspace
    # into new containers via the host daemon.
    if ! command -v act >/dev/null 2>&1; then
        if [[ "${ACT_REQUIRED:-}" == "true" ]]; then
            printf 'Error: act is not installed. Install from https://nektosact.com/\n' >&2
            exit 1
        fi
        printf 'Skipping act-based tests (act not installed)\n'
        return 0
    fi
    make -C "$SCRIPT_DIR" test-actions
}

case "$TEST_TARGET" in
    all)
        run_container_tests test
        run_act_tests
        ;;
    test-actions)
        ACT_REQUIRED=true run_act_tests
        ;;
    *)
        run_container_tests "$TEST_TARGET"
        ;;
esac
