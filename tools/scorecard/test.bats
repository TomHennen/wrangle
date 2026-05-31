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
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scorecard-bats-XXXXXX")"
    export TMP_DIR
    SCRIPT="$ORIG_DIR/tools/scorecard/sarif_to_markdown.sh"
    export SCRIPT
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

@test "scorecard: sarif_to_markdown.sh exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "scorecard: no install.sh exists (action pattern, not adapter)" {
    [ ! -f "$ORIG_DIR/tools/scorecard/install.sh" ]
}

@test "scorecard: no adapter.sh exists (action pattern, not adapter)" {
    [ ! -f "$ORIG_DIR/tools/scorecard/adapter.sh" ]
}

# --- ensure_sarif.sh behavioral tests ---

@test "ensure_sarif: writes a valid empty SARIF when the file is missing" {
    run "$ORIG_DIR/tools/scorecard/ensure_sarif.sh" "$TMP_DIR/out.sarif"
    [ "$status" -eq 0 ]
    [ -f "$TMP_DIR/out.sarif" ]
    run jq -e '.version == "2.1.0" and (.runs[0].results | length) == 0' "$TMP_DIR/out.sarif"
    [ "$status" -eq 0 ]
}

@test "ensure_sarif: leaves an existing SARIF untouched" {
    printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"scorecard"}},"results":[{"ruleId":"R"}]}]}' > "$TMP_DIR/out.sarif"
    run "$ORIG_DIR/tools/scorecard/ensure_sarif.sh" "$TMP_DIR/out.sarif"
    [ "$status" -eq 0 ]
    # The pre-existing result must survive — the script must not overwrite.
    run jq -e '.runs[0].results[0].ruleId == "R"' "$TMP_DIR/out.sarif"
    [ "$status" -eq 0 ]
}

@test "ensure_sarif: usage error with no args" {
    run "$ORIG_DIR/tools/scorecard/ensure_sarif.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "scorecard: action.yml writes to wrangle metadata directory" {
    grep -q '\.wrangle/metadata/scorecard' "$ORIG_DIR/tools/scorecard/action.yml"
}

# --- sarif_to_markdown.sh behavioral tests ---

@test "sarif_to_markdown: emits header and a row per result" {
    cat > "$TMP_DIR/in.sarif" <<'SARIF'
{
  "version": "2.1.0",
  "runs": [{
    "tool": {"driver": {"name": "scorecard"}},
    "results": [
      {"ruleId": "Token-Permissions",
       "message": {"text": "Job permissions too broad"},
       "locations": [{"physicalLocation": {"artifactLocation": {"uri": ".github/workflows/ci.yml"}}}]}
    ]
  }]
}
SARIF
    run "$SCRIPT" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Rule Name | Location | Message"* ]]
    [[ "$output" == *"--------- | -------- | -------"* ]]
    [[ "$output" == *"Token-Permissions | .github/workflows/ci.yml | Job permissions too broad"* ]]
}

@test "sarif_to_markdown: empty results -> header only, exit 0" {
    cat > "$TMP_DIR/in.sarif" <<'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"scorecard"}},"results":[]}]}
SARIF
    run "$SCRIPT" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Rule Name | Location | Message"* ]]
    # No data rows.
    body=$(printf '%s\n' "$output" | tail -n +3)
    [[ -z "$body" ]]
}

@test "sarif_to_markdown: strips HTML tags from message text (no summary HTML rendering)" {
    # Scorecard messages occasionally include <a> tags pointing at the
    # remediation docs. The summary renders as markdown, so HTML must be
    # stripped to prevent confusing rendering — and to defeat any
    # attacker-influenced markup if scorecard ever surfaced upstream text.
    cat > "$TMP_DIR/in.sarif" <<'SARIF'
{
  "version": "2.1.0",
  "runs": [{
    "tool": {"driver": {"name": "scorecard"}},
    "results": [
      {"ruleId": "R", "message": {"text": "see <a href=\"x\">docs</a> for details"},
       "locations": [{"physicalLocation": {"artifactLocation": {"uri": "f"}}}]}
    ]
  }]
}
SARIF
    run "$SCRIPT" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" != *"<a"* ]]
    [[ "$output" != *"</a>"* ]]
    [[ "$output" == *"see docs for details"* ]]
}

@test "sarif_to_markdown: truncates output at WRANGLE_MAX_SUMMARY bytes" {
    # Step summaries have a hard 1 MiB cap; one verbose scorecard run can
    # blow past it. The truncation is the protection.
    {
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"scorecard"}},"results":['
        # 200 results × ~120 bytes each ~= 24 KiB of body.
        for i in $(seq 1 200); do
            [[ "$i" -gt 1 ]] && printf ','
            printf '{"ruleId":"R%d","message":{"text":"msg-%d"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"f%d"}}}]}' "$i" "$i" "$i"
        done
        printf ']}]}'
    } > "$TMP_DIR/in.sarif"
    WRANGLE_MAX_SUMMARY=200 run "$SCRIPT" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    # Output must be bounded by the header lines + 200-byte truncated body.
    [[ "${#output}" -lt 500 ]]
}

@test "sarif_to_markdown: missing file exits 1" {
    run "$SCRIPT" "$TMP_DIR/does-not-exist.sarif"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SARIF file not found"* ]]
}

@test "sarif_to_markdown: invalid JSON exits 2" {
    printf 'not json {{{' > "$TMP_DIR/in.sarif"
    run "$SCRIPT" "$TMP_DIR/in.sarif"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid JSON"* ]]
}

@test "sarif_to_markdown: usage error with no args" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}
