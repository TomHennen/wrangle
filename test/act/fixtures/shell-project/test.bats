#!/usr/bin/env bats

setup() {
    TEST_FIXTURE_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
}

@test "hello.sh exits 0" {
    run bash "$TEST_FIXTURE_DIR/hello.sh"
    [ "$status" -eq 0 ]
}

@test "hello.sh prints greeting" {
    run bash "$TEST_FIXTURE_DIR/hello.sh"
    [[ "$output" == *"Hello"* ]]
}
