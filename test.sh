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

# Build the test container (cached after first run)
echo "=== Building test container ==="
docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/test/Dockerfile" "$SCRIPT_DIR"

# Run the requested test suite
echo "=== Running: $TEST_TARGET ==="
docker run --rm \
    -v "$SCRIPT_DIR":/wrangle:ro \
    -w /wrangle \
    "$IMAGE_NAME" \
    make "$TEST_TARGET"
