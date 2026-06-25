#!/usr/bin/env bats

# Tests for tools/zizmor/ (action pattern).
#
# Action-pattern tools wrap an upstream GitHub Action; there's no
# install.sh or adapter.sh to unit-test. These cover action.yml
# structure, collect_sarif.sh's fail-closed disambiguation, and a
# detection canary that runs the real binary against a known-bad
# workflow. Full integration testing happens via dogfooding in CI.

# skip_or_fail (fail-not-skip under CI) lives in a shared bats helper.
load "../../test/lib/bats_helpers"

setup() {
    ORIG_DIR="$(pwd)"
    export ORIG_DIR
    export TOOL_DIR="$ORIG_DIR/tools/zizmor"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zizmor-bats-XXXXXX")"
    export TMP_DIR
}

teardown() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# Helper: write a SARIF fixture with $1 findings to $2.
make_sarif() {
    local count="$1"
    local dst="$2"
    local results="[]"
    if [[ "$count" -gt 0 ]]; then
        results="$(jq -n --argjson n "$count" '[range($n) | {"ruleId":"TEST-\(.)","message":{"text":"x"}}]')"
    fi
    jq -n --argjson r "$results" \
        '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"zizmor"}},"results":$r}]}' \
        > "$dst"
}

# --- action.yml structure ---

@test "zizmor: action.yml exists and is valid YAML" {
    [ -f "$TOOL_DIR/action.yml" ]
}

@test "zizmor: action.yml pins upstream action to SHA" {
    grep -q 'zizmorcore/zizmor-action@[0-9a-f]\{40\}' "$TOOL_DIR/action.yml"
}

@test "zizmor: action.yml has version input" {
    grep -q 'version:' "$TOOL_DIR/action.yml"
}

@test "zizmor: no install.sh exists (action pattern, not adapter)" {
    [ ! -f "$TOOL_DIR/install.sh" ]
}

@test "zizmor: adapter.sh is the image contract entrypoint" {
    # The containerized zizmor (tools/zizmor/Dockerfile, catalog delivery: image)
    # bundles adapter.sh as its ENTRYPOINT, mapping zizmor's SARIF-mode output to
    # the 0/1/2 exit contract. The action.yml path coexists until the image digest
    # is published and adopters move over.
    [ -f "$TOOL_DIR/adapter.sh" ]
    [ -x "$TOOL_DIR/adapter.sh" ]
}

@test "zizmor: action.yml sets advanced-security to true" {
    # advanced-security: true is required for the upstream action to produce
    # SARIF output. See issue #109 and #114.
    grep -q 'advanced-security: true' "$TOOL_DIR/action.yml"
}

@test "zizmor: action.yml writes to wrangle metadata directory" {
    grep -q '\.wrangle/metadata/zizmor' "$TOOL_DIR/action.yml"
}

@test "zizmor: requirements.txt and action.yml default agree on version" {
    # Local test container installs zizmor via pip --require-hashes from
    # tools/zizmor/requirements.txt; CI uses the upstream Docker action driven
    # by tools/zizmor/action.yml's default version input. Drift between these
    # masks regressions between local pre-push checks and CI. Dependabot bumps
    # requirements.txt; this test makes sure action.yml's default tracks it.
    local req_version action_version
    req_version="$(grep -E '^zizmor==' "$ORIG_DIR/tools/zizmor/requirements.txt" | head -1 | sed -E 's/^zizmor==([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    action_version="$(grep -E '^ +default: "v[0-9]+\.[0-9]+\.[0-9]+"' "$ORIG_DIR/tools/zizmor/action.yml" | sed -E 's/.*"v([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')"
    [ -n "$req_version" ]
    [ -n "$action_version" ]
    [ "$req_version" = "$action_version" ]
}

@test "zizmor: requirements.txt pins zizmor with sha256 hashes" {
    # --require-hashes refuses to install if any artifact lacks a sha256 in
    # this file. Guard against accidental hash removal.
    grep -qE '^zizmor==[0-9]+\.[0-9]+\.[0-9]+' "$ORIG_DIR/tools/zizmor/requirements.txt"
    grep -qE '^ +--hash=sha256:[0-9a-f]{64}' "$ORIG_DIR/tools/zizmor/requirements.txt"
}

@test "zizmor: dependabot tracks tools/zizmor (pip ecosystem)" {
    # If Dependabot loses sight of this directory, hash + version drift
    # against upstream and the wrangle action.yml default goes silent.
    grep -qE 'package-ecosystem: +"pip"' "$ORIG_DIR/.github/dependabot.yml"
    grep -qE '"/tools/(zizmor|\*\*)"' "$ORIG_DIR/.github/dependabot.yml"
}

@test "zizmor: action.yml delegates SARIF collection to a script, not inline shell" {
    # Per CLAUDE.md, run: blocks with logic must be extracted to scripts.
    # The collection step's run: block should just invoke collect_sarif.sh.
    grep -q 'collect_sarif.sh' "$TOOL_DIR/action.yml"
    # The "Collect SARIF output" run: block must contain no inline
    # conditionals — extract everything to collect_sarif.sh. We scope this
    # check to the collection step only; the small "Generate human-readable
    # output" step retains its `[[ -f $SARIF ]]` guard.
    run awk '/^    - name: Collect SARIF output/{flag=1;next} flag && /^    - name:/{flag=0} flag' "$TOOL_DIR/action.yml"
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$output" | grep -Eq '^\s+(if|for|while) '
}

@test "zizmor: action.yml passes upstream output via env, not direct interpolation" {
    # Belt-and-braces: run: blocks must not interpolate ${{ steps.* }}.
    ! grep -E 'run:.*\$\{\{ *steps\.zizmor' "$TOOL_DIR/action.yml"
}

@test "zizmor: action.yml writes the scan/v1 manifest, gated always() and via env" {
    # The manifest step must exist, gate on always() (not hashFiles, which
    # silently skipped the runtime file in #492), thread the SARIF path through
    # env: (no ${{ }} in run:), and call write_scan_manifest.sh with the zizmor
    # token. The no-SARIF / error-marker edge cases live in the script — covered
    # directly by test/test_write_scan_manifest.bats.
    run awk '/^    - name: Write scan manifest/{flag=1;next} flag && /^    - name:/{flag=0} flag' "$TOOL_DIR/action.yml"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q 'if: always()$'
    printf '%s\n' "$output" | grep -Eq 'write_scan_manifest\.sh" zizmor '
    ! printf '%s\n' "$output" | grep -q 'hashFiles'
    ! printf '%s\n' "$output" | grep -q 'run:.*\${{'
}

@test "zizmor: collect_sarif.sh exists and is executable" {
    [ -x "$TOOL_DIR/collect_sarif.sh" ]
}

# --- detection canary: real zizmor still flags a known-bad workflow ---

# A positive control for the scanner itself. Every other test here feeds
# synthetic SARIF or checks action.yml structure — none proves zizmor still
# *detects* anything, so a false-negative regression (a zizmor version that
# stops flagging tag pins, or a config change that silences the audit) would
# pass silently, exactly the gap that let unpinned wrangle examples ship.
# This runs the real binary against a deliberately tag-pinned action and
# asserts unpinned-uses fires. unpinned-uses works offline, so
# --no-online-audits keeps it network-free; SARIF mode always exits 0 (the
# findings live in the document), so the assertion is on SARIF content.
@test "zizmor canary: unpinned-uses fires on a tag-pinned action" {
    command -v zizmor >/dev/null 2>&1 || skip_or_fail "zizmor not on PATH"

    # bash -c redirects zizmor's stderr away so $output is pure SARIF.
    run bash -c "zizmor --no-online-audits --format sarif '$TOOL_DIR/fixtures/unpinned_uses.yml' 2>/dev/null"
    # The ruleId is "zizmor/unpinned-uses"; match the audit name within it.
    printf '%s' "$output" | jq -e \
        '[.runs[].results[] | select(.ruleId | test("unpinned-uses"))] | length >= 1' \
        >/dev/null
}

# --- collect_sarif.sh: fail-closed disambiguation ---

@test "collect_sarif: usage error when metadata dir arg missing" {
    run "$TOOL_DIR/collect_sarif.sh"
    [ "$status" -eq 1 ]
}

@test "collect_sarif: outcome=success + valid SARIF → copy, no marker" {
    # Clean run, zero findings.
    META="$TMP_DIR/meta-clean"
    mkdir -p "$META"
    SRC="$TMP_DIR/src-clean.sarif"
    make_sarif 0 "$SRC"

    SARIF_SRC="$SRC" OUTCOME=success \
        run "$TOOL_DIR/collect_sarif.sh" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/output.sarif" ]
    [ ! -f "$META/error" ]
    # The copied SARIF round-trips correctly.
    jq -e '[.runs[].results[]] | length == 0' "$META/output.sarif" >/dev/null
}

@test "collect_sarif: outcome=failure + valid SARIF with findings → copy, no marker" {
    # A well-formed SARIF reporting >0 results is authoritative regardless
    # of outcome: in SARIF mode zizmor exits 0 even with findings, so an
    # outcome=failure here is the post-write Code Scanning upload failing,
    # not a findings signal. check_results.sh fail-closes via the SARIF
    # count for :fail; :info reports findings informationally, not as error.
    META="$TMP_DIR/meta-findings"
    mkdir -p "$META"
    SRC="$TMP_DIR/src-findings.sarif"
    make_sarif 3 "$SRC"

    SARIF_SRC="$SRC" OUTCOME=failure \
        run "$TOOL_DIR/collect_sarif.sh" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/output.sarif" ]
    [ ! -f "$META/error" ]
    jq -e '[.runs[].results[]] | length == 3' "$META/output.sarif" >/dev/null
}

@test "collect_sarif: outcome=failure + missing SARIF → marker written" {
    META="$TMP_DIR/meta-missing"
    mkdir -p "$META"

    SARIF_SRC="$TMP_DIR/does-not-exist.sarif" OUTCOME=failure \
        run "$TOOL_DIR/collect_sarif.sh" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/error" ]
    grep -q 'outcome=failure' "$META/error"
    # Empty fallback SARIF written so downstream consumers have a file.
    [ -f "$META/output.sarif" ]
    jq -e '[.runs[].results[]] | length == 0' "$META/output.sarif" >/dev/null
}

@test "collect_sarif: outcome=failure + empty SARIF file → marker written" {
    # Upstream `tee` creates the file eagerly; docker crashing before
    # zizmor writes anything leaves it empty. The original fail-open.
    META="$TMP_DIR/meta-empty"
    mkdir -p "$META"
    SRC="$TMP_DIR/src-empty.sarif"
    : > "$SRC"

    SARIF_SRC="$SRC" OUTCOME=failure \
        run "$TOOL_DIR/collect_sarif.sh" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/error" ]
}

@test "collect_sarif: outcome=failure + malformed SARIF → marker written" {
    # docker crashed mid-stream and tee captured truncated/garbled JSON.
    META="$TMP_DIR/meta-bad"
    mkdir -p "$META"
    SRC="$TMP_DIR/src-bad.sarif"
    printf '{not valid json' > "$SRC"

    SARIF_SRC="$SRC" OUTCOME=failure \
        run "$TOOL_DIR/collect_sarif.sh" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/error" ]
}

@test "collect_sarif: outcome=failure + parseable SARIF with zero results → no marker (clean audit, upload failed)" {
    # A complete, parseable SARIF reporting nothing means the audit ran
    # clean. outcome=failure here is the Code Scanning upload failing —
    # it runs after the SARIF is written and fails on repos without
    # Advanced Security — not a zizmor error, so do not fail closed.
    META="$TMP_DIR/meta-zero"
    mkdir -p "$META"
    SRC="$TMP_DIR/src-zero.sarif"
    make_sarif 0 "$SRC"

    SARIF_SRC="$SRC" OUTCOME=failure \
        run "$TOOL_DIR/collect_sarif.sh" "$META"
    [ "$status" -eq 0 ]
    [ ! -f "$META/error" ]
    [ -f "$META/output.sarif" ]
    jq -e '[.runs[].results[]] | length == 0' "$META/output.sarif" >/dev/null
}

@test "collect_sarif: outcome=failure + empty SARIF_SRC env → marker written" {
    # Defensive: if the upstream action ever stops exporting output-file,
    # SARIF_SRC is empty. Combined with outcome=failure that's still a
    # tool error.
    META="$TMP_DIR/meta-emptyenv"
    mkdir -p "$META"

    SARIF_SRC='' OUTCOME=failure \
        run "$TOOL_DIR/collect_sarif.sh" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/error" ]
}

@test "collect_sarif: outcome=success + missing SARIF → no marker, empty fallback" {
    # Upstream succeeded but for some reason produced no file (e.g.,
    # advanced-security: false path). Do not flag as error.
    META="$TMP_DIR/meta-succ-nofile"
    mkdir -p "$META"

    SARIF_SRC="$TMP_DIR/does-not-exist.sarif" OUTCOME=success \
        run "$TOOL_DIR/collect_sarif.sh" "$META"
    [ "$status" -eq 0 ]
    [ ! -f "$META/error" ]
    [ -f "$META/output.sarif" ]
}

@test "collect_sarif: creates metadata directory if missing" {
    META="$TMP_DIR/meta-fresh/zizmor"
    SRC="$TMP_DIR/src-fresh.sarif"
    make_sarif 0 "$SRC"

    SARIF_SRC="$SRC" OUTCOME=success \
        run "$TOOL_DIR/collect_sarif.sh" "$META"
    [ "$status" -eq 0 ]
    [ -f "$META/output.sarif" ]
}
