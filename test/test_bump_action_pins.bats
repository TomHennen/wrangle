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

@test "bump_action_pins: replaces entire trailing comment when branch name contains 'n'/'r'/'\\\\'" {
    # Regression test. Earlier drafts used `[^\\r\\n]*` to match the
    # trailing comment, which BSD sed (macOS) reads as `[^\\rn]*` —
    # the character class stops at the first literal 'r', 'n', or '\\'.
    # On a branch like `claude/implement-npm-build-type-draft` the
    # script would replace `claude/impleme` and leave
    # `nt-npm-build-type-draft <date>` behind in the line. `.*` is
    # portable because sed's pattern space is one line at a time,
    # so `.` is naturally bounded.
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # claude/implement-npm-build-type-draft 2026-05-11
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -q "@${NEW_SHA} # test-branch 2099-12-31" .github/workflows/a.yml
    # No fragment of the old comment may survive — these substrings
    # are what leaked through under BSD sed before the fix.
    ! grep -q "implement-npm-build-type-draft" .github/workflows/a.yml
    ! grep -q "2026-05-11" .github/workflows/a.yml
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

@test "bump_action_pins: ignores commented-out uses: lines" {
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    # uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    uses: TomHennen/wrangle/actions/scan@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    # Commented line untouched
    grep -q "# uses: TomHennen/wrangle/build/actions/python@aaaa" .github/workflows/a.yml
    # Real pin updated
    grep -q "uses: TomHennen/wrangle/actions/scan@${NEW_SHA}" .github/workflows/a.yml
}

@test "bump_action_pins: rejects CRLF line endings" {
    printf 'jobs:\r\n  build:\r\n    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n' > .github/workflows/a.yml
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"CRLF"* ]]
}

@test "bump_action_pins: idempotent when SHA matches even with different env date/branch" {
    # Initial bump with date X, branch Y.
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    "$SCRIPT" "$NEW_SHA" >/dev/null
    BEFORE="$(cat .github/workflows/a.yml)"

    # Re-run with the same SHA but a different date/branch — file must
    # remain byte-identical because the SHA hasn't changed.
    WRANGLE_PINS_DATE=2100-01-01 WRANGLE_PINS_BRANCH=other-branch run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"0 file(s) changed"* ]]
    AFTER="$(cat .github/workflows/a.yml)"
    [[ "$BEFORE" == "$AFTER" ]]
}

@test "bump_action_pins: cleans up temp files on sed failure" {
    # Simulate a permission-denied write to make sed fail. Pre-create
    # a target file, then make the workflows dir non-writable.
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    chmod -w .github/workflows
    run "$SCRIPT" "$NEW_SHA"
    chmod +w .github/workflows
    # Either it errored, or it succeeded but no temp files leaked.
    # Crucial assertion: no leftover .yml.* temp files in the workflows dir.
    leftover_count="$(find .github/workflows -maxdepth 1 -name 'a.yml.*' | wc -l)"
    [[ "$leftover_count" -eq 0 ]]
}

@test "bump_action_pins: handles branch names with sed-special characters" {
    # Branch names can legally contain `|`, `&`, and `\` per
    # git-check-ref-format(1). They flow into the sed REPLACEMENT string
    # for the trailing comment, where each has special meaning. The
    # script must escape them so the rewrite produces a literal label.
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF

    # `|` (the sed delimiter) — must not break the rewrite.
    WRANGLE_PINS_BRANCH='feat|x' run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -qF "@${NEW_SHA} # feat|x" .github/workflows/a.yml

    # `&` (sed's matched-text backreference) — must not be expanded.
    "$SCRIPT" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >/dev/null  # reset to unique pre-state
    WRANGLE_PINS_BRANCH='foo&bar' run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -qF "@${NEW_SHA} # foo&bar" .github/workflows/a.yml

    # `\` (sed's escape character) — must round-trip as a literal backslash.
    "$SCRIPT" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >/dev/null  # reset
    WRANGLE_PINS_BRANCH='back\slash' run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    grep -qF "@${NEW_SHA} # back\\slash" .github/workflows/a.yml
}

# --- Default branch-label detection (issue #173) ---

@test "bump_action_pins: labels as 'main' when target SHA is on main, even from a feature branch" {
    # Setup: a real main branch with a real commit (so target_sha is reachable
    # from main), then a feature branch we run the script from.
    git checkout -q -b main 2>/dev/null || git checkout -q main
    target_sha="$(git rev-parse HEAD)"
    git checkout -q -b cleanup-branch
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    # Don't pass WRANGLE_PINS_BRANCH — exercise default detection.
    unset WRANGLE_PINS_BRANCH
    run "$SCRIPT" "$target_sha"
    [[ "$status" -eq 0 ]]
    grep -qF "# main 2099-12-31" .github/workflows/a.yml
}

@test "bump_action_pins: labels as current branch when target SHA is NOT on main" {
    # Setup: main with one commit, feature branch with an additional commit.
    # Run the script targeting the feature-branch-only commit.
    git checkout -q -b main 2>/dev/null || git checkout -q main
    git checkout -q -b feature
    git commit --allow-empty -q -m "feature work"
    target_sha="$(git rev-parse HEAD)"
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    unset WRANGLE_PINS_BRANCH
    run "$SCRIPT" "$target_sha"
    [[ "$status" -eq 0 ]]
    grep -qF "# feature 2099-12-31" .github/workflows/a.yml
}

@test "bump_action_pins: WRANGLE_PINS_BRANCH overrides auto-detection" {
    # Even when target IS on main, an explicit override wins.
    git checkout -q -b main 2>/dev/null || git checkout -q main
    target_sha="$(git rev-parse HEAD)"
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    WRANGLE_PINS_BRANCH="explicit-label" run "$SCRIPT" "$target_sha"
    [[ "$status" -eq 0 ]]
    grep -qF "# explicit-label 2099-12-31" .github/workflows/a.yml
}

@test "bump_action_pins: WRANGLE_PINS_DEFAULT_BRANCH redirects ancestry check" {
    # If the operator's repo uses `master`, point the merge-base check there.
    # Rename whatever the initial branch is (depends on init.defaultBranch).
    git branch -m master
    target_sha="$(git rev-parse HEAD)"
    git checkout -q -b cleanup-branch
    cat > .github/workflows/a.yml <<EOF
jobs:
  build:
    uses: TomHennen/wrangle/build/actions/python@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    unset WRANGLE_PINS_BRANCH
    WRANGLE_PINS_DEFAULT_BRANCH="master" run "$SCRIPT" "$target_sha"
    [[ "$status" -eq 0 ]]
    grep -qF "# master 2099-12-31" .github/workflows/a.yml
}

@test "bump_action_pins: source pins the subshell exception-safety pattern" {
    # The `set +f` toggle for the glob expansion MUST live inside a
    # subshell so an early exit cannot leak globbing into the parent.
    # A bare `set +f ... set -f` pair only restores on the happy path.
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    grep -q '^[[:space:]]\+set +f' "$REPO_ROOT/tools/bump_action_pins.sh"
    ! grep -q '^set +f' "$REPO_ROOT/tools/bump_action_pins.sh"
}

@test "bump_action_pins: only mixed-SHA files are rewritten when some pins already match target" {
    # File with a mix of SHAs — must be rewritten so all pins reach target.
    cat > .github/workflows/mixed.yml <<EOF
jobs:
  a:
    uses: TomHennen/wrangle/build/actions/python@${NEW_SHA}
  b:
    uses: TomHennen/wrangle/actions/scan@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    # File with all pins already at target — must NOT be rewritten.
    cat > .github/workflows/all-match.yml <<EOF
jobs:
  a:
    uses: TomHennen/wrangle/build/actions/python@${NEW_SHA}
EOF
    run "$SCRIPT" "$NEW_SHA"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"bumped: .github/workflows/mixed.yml"* ]]
    [[ "$output" != *"bumped: .github/workflows/all-match.yml"* ]]
}
