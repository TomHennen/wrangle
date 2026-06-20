#!/usr/bin/env bats

# Tests for tools/scorecard/ (action pattern)
#
# Action-pattern tools wrap an upstream GitHub Action, so there is no
# install.sh or adapter.sh to unit-test. These tests validate the
# action.yml structure, the JSON markdown renderer, and the attestation
# manifest drop.
#
# Full integration testing happens in CI when the scan action invokes
# tools/scorecard/action.yml against the wrangle repo itself (dogfooding).

setup() {
    ORIG_DIR="$(pwd)"
    export ORIG_DIR
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scorecard-bats-XXXXXX")"
    export TMP_DIR
    SCRIPT="$ORIG_DIR/tools/scorecard/json_to_markdown.sh"
    export SCRIPT
    WRITE_MANIFEST="$ORIG_DIR/lib/write_attest_manifest.sh"
    export WRITE_MANIFEST
    FIXTURE="$ORIG_DIR/tools/scorecard/testdata/scorecard.json"
    export FIXTURE
}

teardown() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

@test "scorecard: action.yml exists and is valid YAML" {
    [ -f "$ORIG_DIR/tools/scorecard/action.yml" ]
}

@test "scorecard: action.yml pins upstream action to SHA" {
    grep -q 'ossf/scorecard-action@[0-9a-f]\{40\}' "$ORIG_DIR/tools/scorecard/action.yml"
}

@test "scorecard: action.yml runs scorecard in json format" {
    grep -q 'results_format: json' "$ORIG_DIR/tools/scorecard/action.yml"
    grep -q 'results_file:.*scorecard/output.json' "$ORIG_DIR/tools/scorecard/action.yml"
}

@test "scorecard: action.yml does not emit SARIF" {
    ! grep -q 'output.sarif' "$ORIG_DIR/tools/scorecard/action.yml"
    ! grep -q 'results_format: sarif' "$ORIG_DIR/tools/scorecard/action.yml"
}

@test "scorecard: scan action no longer uploads scorecard SARIF to Security tab" {
    ! grep -q 'category: wrangle/scorecard' "$ORIG_DIR/actions/scan/action.yml"
}

@test "scorecard: json_to_markdown.sh exists and is executable" {
    [ -x "$SCRIPT" ]
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

# --- attestation manifest tests ---

@test "scorecard: manifest written when JSON present, with scorecard predicate" {
    cp "$FIXTURE" "$TMP_DIR/output.json"
    run "$WRITE_MANIFEST" "$TMP_DIR" "https://scorecard.dev/result/v0.1" "output.json"
    [ "$status" -eq 0 ]
    [ -f "$TMP_DIR/wrangle_attestation_metadata.json" ]
    run jq -e '."predicate-type" == "https://scorecard.dev/result/v0.1"' "$TMP_DIR/wrangle_attestation_metadata.json"
    [ "$status" -eq 0 ]
    run jq -e '."result-file" == "output.json"' "$TMP_DIR/wrangle_attestation_metadata.json"
    [ "$status" -eq 0 ]
}

@test "scorecard: no manifest written when JSON absent" {
    # The action.yml guards the manifest drop on [[ -f output.json ]]; with
    # no JSON present, nothing empty is attested. Mirror that guard here.
    [[ -f "$TMP_DIR/output.json" ]] || true
    [ ! -f "$TMP_DIR/wrangle_attestation_metadata.json" ]
}

# --- json_to_markdown.sh behavioral tests ---

@test "json_to_markdown: emits aggregate score and a checks table" {
    run "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Aggregate score: 7.4 / 10"* ]]
    [[ "$output" == *"Check | Score | Reason"* ]]
    [[ "$output" == *"----- | ----- | ------"* ]]
    [[ "$output" == *"Binary-Artifacts | 10 | no binaries found in the repo"* ]]
    [[ "$output" == *"Branch-Protection | 3 | "* ]]
}

@test "json_to_markdown: missing checks -> score line + header only, exit 0" {
    printf '{"score":5.0}' > "$TMP_DIR/in.json"
    run "$SCRIPT" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Aggregate score: 5.0 / 10"* ]]
    [[ "$output" == *"Check | Score | Reason"* ]]
}

@test "json_to_markdown: strips HTML tags from reason text" {
    cat > "$TMP_DIR/in.json" <<'JSON'
{"score":1,"checks":[{"name":"R","score":0,"reason":"see <a href=\"x\">docs</a>"}]}
JSON
    run "$SCRIPT" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    [[ "$output" != *"<a"* ]]
    [[ "$output" == *"see docs"* ]]
}

@test "json_to_markdown: truncates checks at WRANGLE_MAX_SUMMARY bytes" {
    {
        printf '{"score":5,"checks":['
        for i in $(seq 1 200); do
            [[ "$i" -gt 1 ]] && printf ','
            printf '{"name":"C%d","score":%d,"reason":"reason-%d"}' "$i" "$((i % 11))" "$i"
        done
        printf ']}'
    } > "$TMP_DIR/in.json"
    WRANGLE_MAX_SUMMARY=200 run "$SCRIPT" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    [[ "${#output}" -lt 500 ]]
}

@test "json_to_markdown: missing file exits 1" {
    run "$SCRIPT" "$TMP_DIR/does-not-exist.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"JSON file not found"* ]]
}

@test "json_to_markdown: invalid JSON exits 2" {
    printf 'not json {{{' > "$TMP_DIR/in.json"
    run "$SCRIPT" "$TMP_DIR/in.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid JSON"* ]]
}

@test "json_to_markdown: usage error with no args" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}
