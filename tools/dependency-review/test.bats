#!/usr/bin/env bats

# Tests for tools/dependency-review/ (action pattern).
#
# Structural tests on action.yml plus unit tests on the
# vulnerable_changes_to_sarif.sh converter and collect_outputs.sh
# orchestration script, using fixture JSON.

setup() {
    export ORIG_DIR="$(pwd)"
    export TOOL_DIR="$ORIG_DIR/tools/dependency-review"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/depreview-bats-XXXXXX")"
    export TMP_DIR
}

teardown() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

@test "dependency-review: action.yml exists" {
    [ -f "$TOOL_DIR/action.yml" ]
}

@test "dependency-review: action.yml pins upstream action to SHA" {
    grep -q 'actions/dependency-review-action@[0-9a-f]\{40\}' "$TOOL_DIR/action.yml"
}

@test "dependency-review: action.yml has fail-on-severity input" {
    grep -q 'fail-on-severity:' "$TOOL_DIR/action.yml"
}

@test "dependency-review: action.yml has comment-summary-in-pr input defaulted to never" {
    # Default avoids requiring pull-requests: write on adopter workflows.
    # The default: line lives inside the wrapper input block, which has a
    # multi-line description — search a generous window.
    run awk '/^  comment-summary-in-pr:/{flag=1} flag{print} /^[^ ]/{flag=0}' "$TOOL_DIR/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *'default: "never"'* ]]
}

@test "dependency-review: action.yml writes to wrangle metadata directory" {
    grep -q '\.wrangle/metadata/dependency-review' "$TOOL_DIR/action.yml"
}

@test "dependency-review: action.yml uses continue-on-error so SARIF collection runs" {
    grep -q 'continue-on-error: true' "$TOOL_DIR/action.yml"
}

@test "dependency-review: action.yml passes dep-review output via env, not direct interpolation" {
    # Belt-and-braces: the run: block should reference an env var, not
    # a ${{ steps.* }} expression directly.
    ! grep -E 'run:.*\$\{\{ *steps\.depreview' "$TOOL_DIR/action.yml"
}

@test "dependency-review: no install.sh exists (action pattern, not adapter)" {
    [ ! -f "$TOOL_DIR/install.sh" ]
}

@test "dependency-review: no adapter.sh exists (action pattern, not adapter)" {
    [ ! -f "$TOOL_DIR/adapter.sh" ]
}

@test "dependency-review: vulnerable_changes_to_sarif.sh exists and is executable" {
    [ -x "$TOOL_DIR/vulnerable_changes_to_sarif.sh" ]
}

@test "dependency-review: collect_outputs.sh exists and is executable" {
    [ -x "$TOOL_DIR/collect_outputs.sh" ]
}

@test "dependency-review: action.yml delegates SARIF collection to a script, not inline shell" {
    # Per CLAUDE.md, run: blocks with logic must be extracted to scripts.
    # The collection step's run: block should be a single script call.
    grep -q 'collect_outputs.sh' "$TOOL_DIR/action.yml"
    # No conditionals/loops left inline in the action.
    ! grep -Eq '^\s+(if|for|while) ' "$TOOL_DIR/action.yml"
}

# --- Tool-error marker (issue #222) ---

@test "dependency-review: action.yml writes error marker gated on upstream outcome" {
    # The fail-open fix from #222: write a marker the Check results step
    # treats as failure when the upstream action errored out (as opposed
    # to "found issues").
    grep -q "steps.depreview.outcome == 'failure'" "$TOOL_DIR/action.yml"
    grep -q 'mark_error.sh' "$TOOL_DIR/action.yml"
}

@test "dependency-review: mark_error.sh exists and is executable" {
    [ -x "$TOOL_DIR/mark_error.sh" ]
}

@test "mark_error: empty VULNERABLE_CHANGES writes error marker" {
    META="$TMP_DIR/meta-err-empty"
    METADATA_DIR="$META" OUTCOME=failure VULNERABLE_CHANGES='' \
        run "$TOOL_DIR/mark_error.sh"
    [ "$status" -eq 0 ]
    [ -f "$META/error" ]
    grep -q 'outcome=failure' "$META/error"
}

@test "mark_error: literal [] VULNERABLE_CHANGES writes error marker" {
    META="$TMP_DIR/meta-err-empty-arr"
    METADATA_DIR="$META" OUTCOME=failure VULNERABLE_CHANGES='[]' \
        run "$TOOL_DIR/mark_error.sh"
    [ "$status" -eq 0 ]
    [ -f "$META/error" ]
}

@test "mark_error: non-empty VULNERABLE_CHANGES does NOT write error marker" {
    # Findings exit: dep-review populated vulnerable-changes. The SARIF
    # produced by collect_outputs.sh already encodes the findings, so
    # check_results.sh will fail on the SARIF count. Writing an error
    # marker here would misreport findings as a tool error.
    META="$TMP_DIR/meta-findings"
    VC='[{"change_type":"added","manifest":"package.json","ecosystem":"npm","name":"x","version":"1","vulnerabilities":[{"severity":"high","advisory_ghsa_id":"GHSA-x","advisory_summary":"s","advisory_url":"u"}]}]'
    METADATA_DIR="$META" OUTCOME=failure VULNERABLE_CHANGES="$VC" \
        run "$TOOL_DIR/mark_error.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$META/error" ]
}

@test "mark_error: missing METADATA_DIR exits non-zero" {
    run env -u METADATA_DIR OUTCOME=failure VULNERABLE_CHANGES='' "$TOOL_DIR/mark_error.sh"
    [ "$status" -ne 0 ]
}

@test "converter: empty array -> SARIF with zero results" {
    printf '[]' > "$TMP_DIR/in.json"
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    count="$(printf '%s' "$output" | jq '[.runs[].results[]] | length')"
    [ "$count" -eq 0 ]
}

@test "converter: empty file is treated as no findings" {
    : > "$TMP_DIR/in.json"
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    count="$(printf '%s' "$output" | jq '[.runs[].results[]] | length')"
    [ "$count" -eq 0 ]
}

@test "converter: invalid JSON exits 2" {
    printf 'not json' > "$TMP_DIR/in.json"
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 2 ]
}

@test "converter: missing file exits 1" {
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/does-not-exist.json"
    [ "$status" -eq 1 ]
}

@test "converter: single vuln -> one rule, one result, severity mapped" {
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  {
    "change_type": "added",
    "manifest": "package.json",
    "ecosystem": "npm",
    "name": "tough-cookie",
    "version": "2.5.0",
    "package_url": "pkg:npm/tough-cookie@2.5.0",
    "vulnerabilities": [
      {
        "severity": "high",
        "advisory_ghsa_id": "GHSA-72xf-g2v4-qvf3",
        "advisory_summary": "tough-cookie Prototype Pollution",
        "advisory_url": "https://github.com/advisories/GHSA-72xf-g2v4-qvf3"
      }
    ]
  }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]

    # version pinned
    printf '%s' "$output" | jq -e '.version == "2.1.0"' >/dev/null
    # one rule, derived from the GHSA id
    printf '%s' "$output" | jq -e '[.runs[].tool.driver.rules[]] | length == 1' >/dev/null
    printf '%s' "$output" | jq -e '.runs[0].tool.driver.rules[0].id == "GHSA-72xf-g2v4-qvf3"' >/dev/null
    # one result, level "error" for "high"
    printf '%s' "$output" | jq -e '[.runs[].results[]] | length == 1' >/dev/null
    printf '%s' "$output" | jq -e '.runs[0].results[0].level == "error"' >/dev/null
    printf '%s' "$output" | jq -e '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri == "package.json"' >/dev/null
}

@test "converter: severity moderate maps to warning, low maps to note" {
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  { "change_type": "added", "manifest": "a", "ecosystem": "npm", "name": "a", "version": "1",
    "vulnerabilities": [
      { "severity": "moderate", "advisory_ghsa_id": "GHSA-aaa", "advisory_summary": "a", "advisory_url": "u" }
    ]
  },
  { "change_type": "added", "manifest": "b", "ecosystem": "npm", "name": "b", "version": "1",
    "vulnerabilities": [
      { "severity": "low", "advisory_ghsa_id": "GHSA-bbb", "advisory_summary": "b", "advisory_url": "u" }
    ]
  }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.runs[0].results | map(.level) | . == ["warning","note"]' >/dev/null
}

@test "converter: change with no vulnerabilities array produces zero results" {
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  { "change_type": "added", "manifest": "package.json", "ecosystem": "npm", "name": "p", "version": "1" }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '[.runs[].results[]] | length == 0' >/dev/null
    printf '%s' "$output" | jq -e '[.runs[].tool.driver.rules[]] | length == 0' >/dev/null
}

@test "converter: missing advisory_url -> helpUri key omitted (SARIF spec)" {
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  { "change_type": "added", "manifest": "a", "ecosystem": "npm", "name": "a", "version": "1",
    "vulnerabilities": [
      { "severity": "high", "advisory_ghsa_id": "GHSA-aaa", "advisory_summary": "a" }
    ]
  }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    # helpUri must be absent when advisory_url is missing — SARIF 2.1.0
    # rejects empty-string URIs in strict validation.
    printf '%s' "$output" | jq -e '.runs[0].results[0] | has("helpUri") | not' >/dev/null
    printf '%s' "$output" | jq -e '.runs[0].tool.driver.rules[0] | has("helpUri") | not' >/dev/null
}

@test "converter: advisory text with special characters round-trips safely" {
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  { "change_type": "added", "manifest": "p.json", "ecosystem": "npm", "name": "x", "version": "1",
    "vulnerabilities": [
      { "severity": "high",
        "advisory_ghsa_id": "GHSA-xxx",
        "advisory_summary": "He said \"oops\" — newline\nand a backslash \\ and unicode ✓",
        "advisory_url": "https://example.com/a"
      }
    ]
  }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    # Output must still parse as JSON.
    printf '%s' "$output" | jq empty
    # Message text must contain the original summary verbatim (jq does
    # the escaping when serialising back to JSON).
    printf '%s' "$output" | jq -e '.runs[0].results[0].message.text | contains("He said \"oops\"")' >/dev/null
    printf '%s' "$output" | jq -e '.runs[0].results[0].message.text | contains("unicode ✓")' >/dev/null
}

@test "converter: unknown severity falls back to note + 0.0" {
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  { "change_type": "added", "manifest": "p.json", "ecosystem": "npm", "name": "y", "version": "1",
    "vulnerabilities": [
      { "severity": "fizzbuzz", "advisory_ghsa_id": "GHSA-yyy", "advisory_summary": "y", "advisory_url": "u" }
    ]
  }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.runs[0].results[0].level == "note"' >/dev/null
    printf '%s' "$output" | jq -e '.runs[0].results[0].properties["security-severity"] == "0.0"' >/dev/null
}

@test "converter: one rule per unique GHSA across multiple results" {
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  { "change_type": "added", "manifest": "package.json", "ecosystem": "npm", "name": "p1", "version": "1",
    "vulnerabilities": [
      { "severity": "high", "advisory_ghsa_id": "GHSA-xxx", "advisory_summary": "x", "advisory_url": "u" }
    ]
  },
  { "change_type": "added", "manifest": "package.json", "ecosystem": "npm", "name": "p2", "version": "1",
    "vulnerabilities": [
      { "severity": "high", "advisory_ghsa_id": "GHSA-xxx", "advisory_summary": "x", "advisory_url": "u" }
    ]
  }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '[.runs[].tool.driver.rules[]] | length == 1' >/dev/null
    printf '%s' "$output" | jq -e '[.runs[].results[]] | length == 2' >/dev/null
}

@test "converter: change_type removed produces zero results (dropping a vuln dep must not block)" {
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  { "change_type": "removed", "manifest": "package.json", "ecosystem": "npm", "name": "old", "version": "1",
    "vulnerabilities": [
      { "severity": "high", "advisory_ghsa_id": "GHSA-rm", "advisory_summary": "r", "advisory_url": "u" }
    ]
  }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '[.runs[].results[]] | length == 0' >/dev/null
    printf '%s' "$output" | jq -e '[.runs[].tool.driver.rules[]] | length == 0' >/dev/null
}

@test "converter: missing change_type defaults to added (entry is converted)" {
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  { "manifest": "package.json", "ecosystem": "npm", "name": "p", "version": "1",
    "vulnerabilities": [
      { "severity": "high", "advisory_ghsa_id": "GHSA-noct", "advisory_summary": "s", "advisory_url": "u" }
    ]
  }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '[.runs[].results[]] | length == 1' >/dev/null
}

@test "converter: unrecognized change_type is surfaced (fail-safe vs schema drift)" {
    # change_type is currently enum(added, removed). The filter tests
    # `!= "removed"` rather than `== "added"`, so a vulnerable change
    # carrying a value the upstream schema might add later is still
    # flagged rather than silently dropped.
    cat > "$TMP_DIR/in.json" <<'EOF'
[
  { "change_type": "future-unknown-type", "manifest": "package.json", "ecosystem": "npm", "name": "p", "version": "1",
    "vulnerabilities": [
      { "severity": "high", "advisory_ghsa_id": "GHSA-drift", "advisory_summary": "s", "advisory_url": "u" }
    ]
  }
]
EOF
    run "$TOOL_DIR/vulnerable_changes_to_sarif.sh" "$TMP_DIR/in.json"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '[.runs[].results[]] | length == 1' >/dev/null
}

@test "collect_outputs: empty env -> output.sarif + output.md, zero results" {
    META="$TMP_DIR/meta-empty"
    VULNERABLE_CHANGES='' run "$TOOL_DIR/collect_outputs.sh" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/output.sarif" ]
    [ -f "$META/output.md" ]
    jq -e '[.runs[].results[]] | length == 0' "$META/output.sarif" >/dev/null
}

@test "collect_outputs: unset VULNERABLE_CHANGES treated as no findings" {
    META="$TMP_DIR/meta-unset"
    run "$TOOL_DIR/collect_outputs.sh" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/output.sarif" ]
    jq -e '[.runs[].results[]] | length == 0' "$META/output.sarif" >/dev/null
}

@test "collect_outputs: real vulnerable change produces one SARIF result" {
    META="$TMP_DIR/meta-vuln"
    VC='[{"change_type":"added","manifest":"package.json","ecosystem":"npm","name":"x","version":"1","vulnerabilities":[{"severity":"high","advisory_ghsa_id":"GHSA-x","advisory_summary":"s","advisory_url":"https://example.com/a"}]}]'
    VULNERABLE_CHANGES="$VC" run "$TOOL_DIR/collect_outputs.sh" "$META"
    [ "$status" -eq 0 ]
    jq -e '[.runs[].results[]] | length == 1' "$META/output.sarif" >/dev/null
}

@test "collect_outputs: malformed JSON exits 2 and writes no SARIF" {
    META="$TMP_DIR/meta-bad"
    VULNERABLE_CHANGES='not json' run "$TOOL_DIR/collect_outputs.sh" "$META"
    [ "$status" -eq 2 ]
    [ ! -f "$META/output.sarif" ]
}

@test "collect_outputs: usage error when metadata dir arg missing" {
    run "$TOOL_DIR/collect_outputs.sh"
    [ "$status" -eq 1 ]
}
