#!/usr/bin/env bats

setup() {
    FIXTURE_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
}

@test "script.sh exits 0" {
    run bash "$FIXTURE_DIR/script.sh"
    [ "$status" -eq 0 ]
}

@test "script.sh prints greeting" {
    run bash "$FIXTURE_DIR/script.sh"
    [[ "$output" == *"Hello"* ]]
}
