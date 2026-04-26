#!/usr/bin/env bats

# Tests for tools/bump_action_pins.sh.
#
# Each test runs the script in a temporary git repo with a fabricated
# .github/workflows/ tree so we exercise the rewrite logic against
# representative inputs without touching the real wrangle repo.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/tools/bump_action_pins.sh"
    TEST_DIR="$(mktemp -d)"
    ORIG_DIR="$(pwd)"

    cd "$TEST_DIR"
    git init -q
    git config user.email "t@t"
    git config user.name "t"
    git commit --allow-empty -q -m init
    mkdir -p .github/workflows

    # Stable comment env so test assertions don't drift with date.
    export WRANGLE_PINS_BRANCH=test-branch
    export WRANGLE_PINS_DATE=2099-12-31

    NEW_SHA="cccccccccccccccccccccccccccccccccccccccc"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

@test "bump_action_pins: rewrites pin with existing comment" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # main 2026-01-01
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -q "@${NEW_SHA} # test-branch 2099-12-31" .github/workflows/a.yml
    ! grep -q "@aaaa" .github/workflows/a.yml
}

@test "bump_action_pins: adds comment when pin lacks one" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/actions/scan@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -q "@${NEW_SHA} # test-branch 2099-12-31" .github/workflows/a.yml
}

@test "bump_action_pins: leaves unrelated action refs alone" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      - uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -q "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2" .github/workflows/a.yml
    grep -q "TomHennen/wrangle/build/actions/python@${NEW_SHA}" .github/workflows/a.yml
}

@test "bump_action_pins: leaves third-party SLSA generator tag refs alone" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  provenance:
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.1.0
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -q "slsa-framework/slsa-github-generator.*@v2.1.0" .github/workflows/a.yml
}

@test "bump_action_pins: handles multiple pins in one file" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  a:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # main 2026-01-01
  b:
    uses: TomHennen/wrangle/actions/scan@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # main 2026-02-01
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    [[ "$(grep -c "@${NEW_SHA}" .github/workflows/a.yml)" -eq 2 ]]
}

@test "bump_action_pins: handles multiple files" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    cat > .github/workflows/b.yml <<EOF
jobs:
  scan:
    uses: TomHennen/wrangle/actions/scan@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -q "@${NEW_SHA}" .github/workflows/a.yml
    grep -q "@${NEW_SHA}" .github/workflows/b.yml
}

@test "bump_action_pins: idempotent on second run" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    "$SCRIPT" "$NEW_SHA" >/dev/null
    BEFORE="$(cat .github/workflows/a.yml)"
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"0 file(s) changed"* ]]
    AFTER="$(cat .github/workflows/a.yml)"
    [[ "$BEFORE" == "$AFTER" ]]
}

@test "bump_action_pins: defaults to current HEAD when no SHA given" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    git add . && git commit -q -m fixture
    HEAD_SHA="$(git rev-parse HEAD)"
    run "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -q "@${HEAD_SHA}" .github/workflows/a.yml
}

@test "bump_action_pins: rejects non-SHA argument" {
    run "$SCRIPT" "not-a-sha"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"40-char hex"* ]]
}

@test "bump_action_pins: rejects too many arguments" {
    run "$SCRIPT" "$NEW_SHA" extra
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Usage"* ]]
}

@test "bump_action_pins: errors when not in a git working tree" {
    NON_GIT="$(mktemp -d)"
    cd "$NON_GIT"
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"git working tree"* ]]
    rm -rf "$NON_GIT"
}

@test "bump_action_pins: WRANGLE_PINS_REPO override targets a different prefix" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: example/repo/path@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    other:
    uses: TomHennen/wrangle/build/actions/python@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
    WRANGLE_PINS_REPO=example/repo run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -q "example/repo/path@${NEW_SHA}" .github/workflows/a.yml
    # Default prefix should NOT be touched when override is set
    grep -q "TomHennen/wrangle/build/actions/python@bbbb" .github/workflows/a.yml
}

@test "bump_action_pins: matches both .yml and .yaml extensions" {
    cat > .github/workflows/a.yaml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -q "@${NEW_SHA}" .github/workflows/a.yaml
}
