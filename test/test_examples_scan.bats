#!/usr/bin/env bats

# Dogfoods the adopter-facing example workflows in gh_workflow_examples/.
#
# These are the files the docs tell adopters to copy into .github/workflows/,
# yet nothing scans them: zizmor's directory walk only collects files already
# under a .github/workflows/ path, and the pin-consistency guard only compares
# SHAs among refs already pinned by SHA — a tag-pinned wrangle ref (the
# regression that shipped unpinned examples) matches neither. This stages each
# example the way an adopter would and runs the real scanner over it, so an
# unpinned/tag-pinned reference fails CI here instead of on an adopter's first
# run on the line wrangle told them to add.

# skip_or_fail (fail-not-skip under CI) lives in a shared bats helper.
load "lib/bats_helpers"

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/examples-scan-XXXXXX")"
    export TMP_DIR
}

teardown() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

@test "example workflows pass the same zizmor scan an adopter runs" {
    command -v zizmor >/dev/null 2>&1 || skip_or_fail "zizmor not on PATH"

    mkdir -p "$TMP_DIR/.github/workflows"
    local staged=0 f
    for f in "$REPO_ROOT"/gh_workflow_examples/*.yml; do
        # Stage only real workflows. The directory also holds goreleaser
        # configs and dependabot.yml, which have no top-level jobs: key;
        # zizmor crashes when handed a goreleaser file as a workflow.
        grep -qE '^jobs:' "$f" || continue
        cp "$f" "$TMP_DIR/.github/workflows/"
        staged=$((staged + 1))
    done
    # Guard against the glob/grep silently selecting nothing.
    [ "$staged" -gt 0 ]

    # zizmor exits 0 clean, 14 on findings; --no-online-audits still runs
    # unpinned-uses (it works offline), which is the audit that catches a
    # tag-pinned wrangle reference.
    run zizmor --no-online-audits "$TMP_DIR"
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}
