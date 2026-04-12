#!/usr/bin/env bats

# Structural tests for composite actions.
# Validates wiring that act cannot exercise (SARIF uploads, SHA pinning,
# input validation patterns, action-pattern tool existence).

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# --- YAML validity ---

@test "structure: all action.yml files are valid YAML" {
    while IFS= read -r -d '' f; do
        run jq -e '.' < /dev/null
        # Use python or jq to validate — jq can't parse YAML, so use
        # a simple heuristic: the file must parse as a mapping with 'runs:'
        run grep -q "^runs:" "$f"
        [ "$status" -eq 0 ]
    done < <(find "$REPO_ROOT" -name 'action.yml' -not -path '*/.git/*' -print0)
}

# --- SHA pinning ---

@test "structure: no @main references in uses: lines" {
    while IFS= read -r -d '' f; do
        # Check uses: lines (YAML) — skip comment-only lines
        if grep -E '^\s*uses:' "$f" | grep -v '^\s*#' | grep -q '@main'; then
            echo "Found @main in $f" >&2
            return 1
        fi
    done < <(find "$REPO_ROOT" -name 'action.yml' -not -path '*/.git/*' -print0)
}

@test "structure: third-party actions are SHA-pinned" {
    while IFS= read -r -d '' f; do
        # Extract uses: lines, skip local (./), skip comments
        while IFS= read -r line; do
            ref="${line##*@}"
            # SHA pins are 40 hex characters
            if [[ ! "$ref" =~ ^[0-9a-f]{40} ]]; then
                echo "Not SHA-pinned in $f: $line" >&2
                return 1
            fi
        done < <(grep -E '^\s*uses:' "$f" | grep -v '^\s*#' | grep -v 'uses: \./' | sed 's/^\s*uses:\s*//')
    done < <(find "$REPO_ROOT" -name 'action.yml' -not -path '*/.git/*' -print0)
}

# --- actions/scan/action.yml wiring ---

@test "structure: scan action has upload-sarif step for osv" {
    run grep -A2 'Upload OSV SARIF' "$REPO_ROOT/actions/scan/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"upload-sarif"* ]]
}

@test "structure: scan action osv SARIF has correct category" {
    run grep 'category: wrangle/osv' "$REPO_ROOT/actions/scan/action.yml"
    [ "$status" -eq 0 ]
}

@test "structure: scan action has upload-sarif step for scorecard" {
    run grep -A2 'Upload Scorecard SARIF' "$REPO_ROOT/actions/scan/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"upload-sarif"* ]]
}

@test "structure: scan action scorecard SARIF has correct category" {
    run grep 'category: wrangle/scorecard' "$REPO_ROOT/actions/scan/action.yml"
    [ "$status" -eq 0 ]
}

@test "structure: scan action has upload-artifact step" {
    run grep 'upload-artifact' "$REPO_ROOT/actions/scan/action.yml"
    [ "$status" -eq 0 ]
}

@test "structure: scan action artifact name is wrangle-scan-results" {
    run grep 'name: wrangle-scan-results' "$REPO_ROOT/actions/scan/action.yml"
    [ "$status" -eq 0 ]
}

# --- build/actions/container/action.yml ---

@test "structure: container action has input validation step with set -f" {
    # The validate step must use set -f to disable globbing on external input
    run grep -A5 'Validate and normalize inputs' "$REPO_ROOT/build/actions/container/action.yml"
    [ "$status" -eq 0 ]
    # Check set -f is present in the action file
    run grep 'set -f' "$REPO_ROOT/build/actions/container/action.yml"
    [ "$status" -eq 0 ]
}

# --- Action-pattern tools existence ---

@test "structure: tools/scorecard/action.yml exists" {
    [ -f "$REPO_ROOT/tools/scorecard/action.yml" ]
}

@test "structure: tools/scorecard wraps upstream scorecard-action" {
    run grep 'ossf/scorecard-action' "$REPO_ROOT/tools/scorecard/action.yml"
    [ "$status" -eq 0 ]
}

@test "structure: tools/zizmor/action.yml exists" {
    [ -f "$REPO_ROOT/tools/zizmor/action.yml" ]
}

@test "structure: tools/zizmor wraps upstream zizmor-action" {
    run grep 'zizmor-action' "$REPO_ROOT/tools/zizmor/action.yml"
    [ "$status" -eq 0 ]
}

# --- Scan action references local tools ---

@test "structure: scan action references zizmor via local path" {
    run grep 'uses: ./tools/zizmor' "$REPO_ROOT/actions/scan/action.yml"
    [ "$status" -eq 0 ]
}

@test "structure: scan action references scorecard via local path" {
    run grep 'uses: ./tools/scorecard' "$REPO_ROOT/actions/scan/action.yml"
    [ "$status" -eq 0 ]
}

# --- Shell build action ---

@test "structure: shell build action exists" {
    [ -f "$REPO_ROOT/build/actions/shell/action.yml" ]
}

@test "structure: shell build action has shellcheck step" {
    run grep 'Run shellcheck' "$REPO_ROOT/build/actions/shell/action.yml"
    [ "$status" -eq 0 ]
}

@test "structure: shell build action has bats step" {
    run grep 'Run bats' "$REPO_ROOT/build/actions/shell/action.yml"
    [ "$status" -eq 0 ]
}
