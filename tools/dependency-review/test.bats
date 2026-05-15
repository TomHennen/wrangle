#!/usr/bin/env bats

# Tests for tools/dependency-review/ (action pattern).
#
# Structural tests on action.yml plus unit tests on the
# vulnerable_changes_to_sarif.sh converter using fixture JSON.

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
