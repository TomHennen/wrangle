#!/usr/bin/env bats

# Tests for tools/zizmor/ (image pattern).
#
# zizmor ships as a contract image (catalog image entry); adapter.sh is its
# ENTRYPOINT, mapping `zizmor --format sarif` to the 0/1/2 exit contract. These
# cover that mapping through a PATH shim (the invalid-SARIF / tool-error / no-
# inputs branches a real scanner won't emit on demand), the requirements pin +
# Dependabot wiring the image build depends on, and a detection canary that runs
# the real binary against a known-bad workflow. The image itself is exercised
# end-to-end by test/image/test_zizmor_image.bats.

# skip_or_fail (fail-not-skip under CI) lives in a shared bats helper.
load "../../test/lib/bats_helpers"

setup() {
    ORIG_DIR="$(pwd)"
    export ORIG_DIR
    export TOOL_DIR="$ORIG_DIR/tools/zizmor"
    ADAPTER="$TOOL_DIR/adapter.sh"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zizmor-bats-XXXXXX")"
    BIN_DIR="$TMP_DIR/bin"
    SRC="$TMP_DIR/src"
    OUT="$TMP_DIR/out"
    mkdir -p "$BIN_DIR" "$SRC" "$OUT"
    export ADAPTER TMP_DIR BIN_DIR SRC OUT
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }

    # A fake zizmor whose behavior is selected by $ZZ_SHIM_MODE. zizmor writes
    # SARIF to stdout (the adapter redirects it to output.sarif); the no-inputs
    # case exits 3 with no output, which the adapter turns into a clean run.
    cat > "$BIN_DIR/zizmor" <<'SHIM'
#!/usr/bin/env bash
case "${ZZ_SHIM_MODE:-clean}" in
    clean)
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"zizmor"}},"results":[]}]}\n' ;;
    findings)
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"zizmor"}},"results":[{"ruleId":"zizmor/unpinned-uses","message":{"text":"x"}}]}]}\n' ;;
    no-inputs)
        exit 3 ;;
    toolerror)
        exit 2 ;;
    invalid)
        printf '{ not valid json\n' ;;
    no-runs)
        printf '{"version":"2.1.0"}\n' ;;
esac
exit 0
SHIM
    chmod +x "$BIN_DIR/zizmor"
    PATH="$BIN_DIR:$PATH"
    export PATH
}

teardown() {
    cd "$ORIG_DIR" || true
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# --- adapter.sh: exit-code contract through a PATH-shimmed zizmor ---

@test "zizmor adapter: adapter.sh is the image contract entrypoint" {
    [ -f "$ADAPTER" ]
    [ -x "$ADAPTER" ]
}

@test "zizmor adapter: no findings -> exit 0, empty SARIF" {
    ZZ_SHIM_MODE=clean run "$ADAPTER" "$SRC" "$OUT"
    [ "$status" -eq 0 ]
    [ -f "$OUT/output.sarif" ]
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

@test "zizmor adapter: findings -> exit 1, SARIF passed through" {
    ZZ_SHIM_MODE=findings run "$ADAPTER" "$SRC" "$OUT"
    [ "$status" -eq 1 ]
    [[ "$(jq -r '.runs[].results[].ruleId' "$OUT/output.sarif")" == *"unpinned-uses"* ]]
}

@test "zizmor adapter: no inputs collected (exit 3) -> exit 0, synthesized empty SARIF" {
    ZZ_SHIM_MODE=no-inputs run "$ADAPTER" "$SRC" "$OUT"
    [ "$status" -eq 0 ]
    [ -f "$OUT/output.sarif" ]
    [ "$(jq '[.runs[].results[]] | length' "$OUT/output.sarif")" -eq 0 ]
}

@test "zizmor adapter: binary tool error -> exit 2" {
    ZZ_SHIM_MODE=toolerror run "$ADAPTER" "$SRC" "$OUT"
    [ "$status" -eq 2 ]
}

@test "zizmor adapter: invalid SARIF JSON -> exit 2" {
    ZZ_SHIM_MODE=invalid run "$ADAPTER" "$SRC" "$OUT"
    [ "$status" -eq 2 ]
}

@test "zizmor adapter: SARIF missing runs array -> exit 2" {
    ZZ_SHIM_MODE=no-runs run "$ADAPTER" "$SRC" "$OUT"
    [ "$status" -eq 2 ]
}

@test "zizmor adapter: requires 2 arguments" {
    run "$ADAPTER" "$SRC"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]
}

@test "zizmor adapter: missing source directory -> exit 2" {
    run "$ADAPTER" "$TMP_DIR/does-not-exist" "$OUT"
    [ "$status" -eq 2 ]
}

@test "zizmor adapter: missing output directory -> exit 2" {
    run "$ADAPTER" "$SRC" "$TMP_DIR/does-not-exist"
    [ "$status" -eq 2 ]
}

# --- requirements pin + Dependabot: the image build's integrity inputs ---

@test "zizmor: requirements.txt pins zizmor with sha256 hashes" {
    # The image installs zizmor via pip --require-hashes from this file, which
    # refuses any artifact whose sha256 isn't listed. Guard against accidental
    # hash removal.
    grep -qE '^zizmor==[0-9]+\.[0-9]+\.[0-9]+' "$TOOL_DIR/requirements.txt"
    grep -qE '^ +--hash=sha256:[0-9a-f]{64}' "$TOOL_DIR/requirements.txt"
}

@test "zizmor: dependabot tracks tools/zizmor (pip ecosystem)" {
    # If Dependabot loses sight of this directory, hash + version drift against
    # upstream and the image's pinned zizmor goes silently stale.
    grep -qE 'package-ecosystem: +"pip"' "$ORIG_DIR/.github/dependabot.yml"
    grep -qE '"/tools/(zizmor|\*\*)"' "$ORIG_DIR/.github/dependabot.yml"
}

# --- detection canary: real zizmor still flags a known-bad workflow ---

# A positive control for the scanner itself. Every other test here feeds
# synthetic SARIF or checks structure — none proves zizmor still *detects*
# anything, so a false-negative regression (a zizmor version that stops flagging
# tag pins, or a config change that silences the audit) would pass silently,
# exactly the gap that let unpinned wrangle examples ship. This runs the real
# binary against a deliberately tag-pinned action and asserts unpinned-uses
# fires. unpinned-uses works offline, so --no-online-audits keeps it network-
# free; SARIF mode always exits 0 (the findings live in the document), so the
# assertion is on SARIF content.
@test "zizmor canary: unpinned-uses fires on a tag-pinned action" {
    # Drop the shimmed zizmor from PATH so the canary drives the real binary.
    export PATH="${PATH#"$BIN_DIR":}"
    command -v zizmor >/dev/null 2>&1 || skip_or_fail "zizmor not on PATH"

    # bash -c redirects zizmor's stderr away so $output is pure SARIF.
    run bash -c "zizmor --no-online-audits --format sarif '$TOOL_DIR/fixtures/unpinned_uses.yml' 2>/dev/null"
    # The ruleId is "zizmor/unpinned-uses"; match the audit name within it.
    printf '%s' "$output" | jq -e \
        '[.runs[].results[] | select(.ruleId | test("unpinned-uses"))] | length >= 1' \
        >/dev/null
}
