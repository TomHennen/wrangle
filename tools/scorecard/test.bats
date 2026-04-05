#!/usr/bin/env bats

# Tests for tools/scorecard/ (action pattern)
#
# Action-pattern tools wrap an upstream GitHub Action, so there is no
# install.sh or adapter.sh to unit-test. These tests validate the
# action.yml structure and that supporting files are correct.
#
# Full integration testing happens in CI when the scan action invokes
# tools/scorecard/action.yml against the wrangle repo itself (dogfooding).

setup() {
    export ORIG_DIR="$(pwd)"
}

@test "scorecard: action.yml exists and is valid YAML" {
    [ -f "$ORIG_DIR/tools/scorecard/action.yml" ]
}

@test "scorecard: action.yml pins upstream action to SHA" {
    grep -q 'ossf/scorecard-action@[0-9a-f]\{40\}' "$ORIG_DIR/tools/scorecard/action.yml"
}

@test "scorecard: sarif_to_markdown.sh exists and is executable" {
    [ -x "$ORIG_DIR/tools/scorecard/sarif_to_markdown.sh" ]
}

@test "scorecard: no install.sh exists (action pattern, not adapter)" {
    [ ! -f "$ORIG_DIR/tools/scorecard/install.sh" ]
}

@test "scorecard: no adapter.sh exists (action pattern, not adapter)" {
    [ ! -f "$ORIG_DIR/tools/scorecard/adapter.sh" ]
}

@test "scorecard: action.yml writes to wrangle metadata directory" {
    grep -q '\.wrangle/metadata/scorecard' "$ORIG_DIR/tools/scorecard/action.yml"
}
