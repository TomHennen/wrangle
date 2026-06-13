#!/usr/bin/env bats

# Tests for tools/wrangle-lint/adapter.sh — the adopter configuration linter
# (v1: Dependabot config correctness). Drives the adapter end to end against
# fixture repo trees and asserts on exit codes and the emitted SARIF.
#
# Layout:
#   - fixtures/<case>/.github/dependabot.{yml,yaml} are committed repo trees
#     (a nested dependabot.yml is inert — Dependabot reads only the repo-root
#     one — so they don't affect the wrangle repo's own config).
#   - Cases that need a composite action.yml on disk (WL004) or a missing file
#     (WL001) use mktemp trees so no stray action.yml trips the repo linters.
#   - The suite is hermetic: shell + python + jq + fixtures, no network, no
#     real scanner, so nothing skips in CI.

setup() {
    ORIG_DIR="$(pwd)"
    ADAPTER="$ORIG_DIR/tools/wrangle-lint/adapter.sh"
    FIXTURES="$ORIG_DIR/tools/wrangle-lint/fixtures"
    OUT="$(mktemp -d)"
    export ORIG_DIR ADAPTER FIXTURES OUT

    # Fail loud if no python3 with PyYAML is reachable — the adapter resolves
    # the same way, and a silent skip would let a broken image ship green.
    if [[ -x /opt/wrangle-lint/bin/python3 ]]; then
        PY=/opt/wrangle-lint/bin/python3
    elif command -v python3 >/dev/null 2>&1; then
        PY=python3
    else
        printf 'python3 not on PATH — run via ./test.sh (the Docker image provides it)\n' >&2
        return 1
    fi
    if ! "$PY" -c 'import yaml' >/dev/null 2>&1; then
        printf 'PyYAML not importable — install tools/wrangle-lint/requirements.txt into a venv (see test/Dockerfile)\n' >&2
        return 1
    fi
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }
}

teardown() {
    rm -rf "$OUT"
    cd "$ORIG_DIR" || true
}

rule_ids() {
    jq -r '.runs[].results[].ruleId' "$OUT/output.sarif"
}

# --- Negative fixture --------------------------------------------------------

@test "clean config: no findings" {
    run "$ADAPTER" "$FIXTURES/good" "$OUT"
    [ "$status" -eq 0 ]
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

# --- WL001: missing config ---------------------------------------------------

@test "WL001: a repo with no dependabot config is reported" {
    src="$(mktemp -d)"
    run "$ADAPTER" "$src" "$OUT"
    rm -rf "$src"
    [ "$status" -eq 1 ]
    [[ "$(rule_ids)" == *"WL001"* ]]
}

# --- WL002: wrong extension --------------------------------------------------

@test "WL002: config at dependabot.yaml is reported (Dependabot ignores it)" {
    run "$ADAPTER" "$FIXTURES/yaml_ext" "$OUT"
    [ "$status" -eq 1 ]
    [[ "$(rule_ids)" == *"WL002"* ]]
}

# --- WL003: non-recursing github-actions glob -------------------------------

@test "WL003: a github-actions /** glob is reported" {
    run "$ADAPTER" "$FIXTURES/glob_ga" "$OUT"
    [ "$status" -eq 1 ]
    [[ "$(rule_ids)" == *"WL003"* ]]
}

# --- WL004: composite directory not enumerated ------------------------------

@test "WL004: a composite action dir absent from directories is reported" {
    src="$(mktemp -d)"
    mkdir -p "$src/.github" "$src/myaction"
    printf 'version: 2\nupdates:\n  - package-ecosystem: "github-actions"\n    directory: "/"\n    cooldown:\n      default-days: 7\n' > "$src/.github/dependabot.yml"
    printf 'name: x\nruns:\n  using: composite\n  steps: []\n' > "$src/myaction/action.yml"
    run "$ADAPTER" "$src" "$OUT"
    rm -rf "$src"
    [ "$status" -eq 1 ]
    [[ "$(rule_ids)" == *"WL004"* ]]
}

@test "WL004: a composite dir that IS listed is not flagged" {
    src="$(mktemp -d)"
    mkdir -p "$src/.github" "$src/myaction"
    printf 'version: 2\nupdates:\n  - package-ecosystem: "github-actions"\n    directories:\n      - "/"\n      - "/myaction"\n    cooldown:\n      default-days: 7\n' > "$src/.github/dependabot.yml"
    printf 'name: x\nruns:\n  using: composite\n  steps: []\n' > "$src/myaction/action.yml"
    run "$ADAPTER" "$src" "$OUT"
    rm -rf "$src"
    [ "$status" -eq 0 ]
    [[ "$(rule_ids)" != *"WL004"* ]]
}

# --- WL005: cooldown --------------------------------------------------------

@test "WL005: an entry with no cooldown is reported" {
    run "$ADAPTER" "$FIXTURES/no_cooldown" "$OUT"
    [ "$status" -eq 1 ]
    [[ "$(rule_ids)" == *"WL005"* ]]
}

@test "WL005: a cooldown shorter than the adoption delay is reported" {
    src="$(mktemp -d)"
    mkdir -p "$src/.github"
    printf 'version: 2\nupdates:\n  - package-ecosystem: "github-actions"\n    directory: "/"\n    cooldown:\n      default-days: 2\n' > "$src/.github/dependabot.yml"
    run "$ADAPTER" "$src" "$OUT"
    rm -rf "$src"
    [ "$status" -eq 1 ]
    [[ "$(rule_ids)" == *"WL005"* ]]
}

# --- Suppression ------------------------------------------------------------

@test "a justified ignore comment suppresses the finding" {
    run "$ADAPTER" "$FIXTURES/suppressed" "$OUT"
    [ "$status" -eq 0 ]
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

@test "an ignore comment without a justification does not suppress" {
    src="$(mktemp -d)"
    mkdir -p "$src/.github"
    printf 'version: 2\nupdates:\n  - package-ecosystem: "github-actions"\n    directories:\n      # wrangle-lint: ignore WL003\n      - "/**"\n    cooldown:\n      default-days: 7\n' > "$src/.github/dependabot.yml"
    run "$ADAPTER" "$src" "$OUT"
    rm -rf "$src"
    [ "$status" -eq 1 ]
    [[ "$(rule_ids)" == *"WL003"* ]]
}

@test "an ignore for a different rule does not suppress" {
    src="$(mktemp -d)"
    mkdir -p "$src/.github"
    printf 'version: 2\nupdates:\n  - package-ecosystem: "github-actions"\n    directories:\n      # wrangle-lint: ignore WL005 -- wrong rule id\n      - "/**"\n    cooldown:\n      default-days: 7\n' > "$src/.github/dependabot.yml"
    run "$ADAPTER" "$src" "$OUT"
    rm -rf "$src"
    [ "$status" -eq 1 ]
    [[ "$(rule_ids)" == *"WL003"* ]]
}

# --- Tool-error handling ----------------------------------------------------

@test "malformed dependabot.yml fails closed (exit 2)" {
    src="$(mktemp -d)"
    mkdir -p "$src/.github"
    printf 'updates:\n  - bad: [unclosed\n' > "$src/.github/dependabot.yml"
    run "$ADAPTER" "$src" "$OUT"
    rm -rf "$src"
    [ "$status" -eq 2 ]
}

@test "a missing output directory is a tool error (exit 2)" {
    run "$ADAPTER" "$FIXTURES/good" "$OUT/does-not-exist"
    [ "$status" -eq 2 ]
}

# --- Output format ----------------------------------------------------------

@test "output is valid SARIF naming the wrangle-lint driver" {
    run "$ADAPTER" "$FIXTURES/glob_ga" "$OUT"
    [ "$status" -eq 1 ]
    [ "$(jq -r '.runs[0].tool.driver.name' "$OUT/output.sarif")" = "wrangle-lint" ]
    [ "$(jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$OUT/output.sarif")" = ".github/dependabot.yml" ]
}

# --- Dogfood ----------------------------------------------------------------

@test "dogfood: the wrangle repo's own config passes (exit 0)" {
    run "$ADAPTER" "$ORIG_DIR" "$OUT"
    [ "$status" -eq 0 ]
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

# --- PyYAML pin drift guard -------------------------------------------------
# check.py and wrangle-workflow-lint/lint.py both import PyYAML from their own
# hash-pinned requirements.txt; the two MUST stay on the same version+hashes so
# a Dependabot bump to one can't leave the other behind (DEP_MGMT.md § Drift).

@test "PyYAML pin matches wrangle-workflow-lint (no drift)" {
    a="$ORIG_DIR/tools/wrangle-lint/requirements.txt"
    b="$ORIG_DIR/tools/wrangle-workflow-lint/requirements.txt"
    pins_a="$(grep -E '^(PyYAML==|[[:space:]]*--hash=)' "$a")"
    pins_b="$(grep -E '^(PyYAML==|[[:space:]]*--hash=)' "$b")"
    [ "$pins_a" = "$pins_b" ]
}
