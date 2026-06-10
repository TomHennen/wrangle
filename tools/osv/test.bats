#!/usr/bin/env bats

# Tests for tools/osv/ — install.sh, adapter.sh, and render_md.sh.
#
# Three layers, mirroring the pattern adopted in #236:
#
#   1. render_md.sh — direct behavioral tests. Inline SARIF fixtures
#      describe a specific input; assertions are on stdout/exit code.
#      No mock binary involved.
#
#   2. adapter.sh — end-to-end through a PATH-shimmed osv-scanner.
#      The shim emits canned SARIF (controlled by OSV_MOCK_MODE) so
#      these tests cover the adapter's exit-code contract, SARIF
#      validation, output-directory handling, and the wiring between
#      adapter → render_md.sh.
#
#   3. install.sh — go-module install tests (structural + idempotency;
#      `go list -m` reads go.mod locally). No real builds.
#
# Plus one opt-in e2e (`@test "osv e2e: ..."`) that runs the real
# osv-scanner against a deliberately-vulnerable manifest. Skips if
# osv-scanner is not on PATH or the osv.dev API is unreachable (which
# is the case in sandboxed CI environments).

# skip_or_fail (fail-not-skip under CI) lives in a shared bats helper.
load "../../test/lib/bats_helpers"

setup() {
    ORIG_DIR="$(pwd)"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/osv-bats-XXXXXX")"
    MOCK_BIN="$TMP_DIR/mock_bin"
    export ORIG_DIR TMP_DIR MOCK_BIN

    ADAPTER="$ORIG_DIR/tools/osv/adapter.sh"
    RENDER="$ORIG_DIR/tools/osv/render_md.sh"
    INSTALL="$ORIG_DIR/tools/osv/install.sh"
    REAL_FIXTURE="$ORIG_DIR/tools/osv/testdata/real_osv_findings.sarif"
    export ADAPTER RENDER INSTALL REAL_FIXTURE

    mkdir -p "$MOCK_BIN" "$TMP_DIR/src" "$TMP_DIR/output"

    # Mock osv-scanner used by the adapter-layer tests. Behaviour is
    # selected via OSV_MOCK_MODE: clean | findings | real-findings |
    # no-sources | error | bad-json. The real binary is exercised only
    # by the opt-in e2e test (which removes this mock from PATH first).
    cat > "$MOCK_BIN/osv-scanner" << 'MOCK'
#!/bin/bash
for arg in "$@"; do
    if [[ "$arg" == "--version" ]]; then
        printf 'osv-scanner version 2.3.5-mock\n'
        exit 0
    fi
done

output_file=""
format=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output_file="$2"; shift 2 ;;
        --format) format="$2"; shift 2 ;;
        *) shift ;;
    esac
done

case "${OSV_MOCK_MODE:-clean}" in
    clean)
        if [[ "$format" == "sarif" ]]; then
            cat > "$output_file" << 'SARIF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [{"tool": {"driver": {"name": "osv-scanner", "version": "2.3.5"}}, "results": []}]
}
SARIF
        fi
        exit 0
        ;;
    findings)
        if [[ "$format" == "sarif" ]]; then
            cat > "$output_file" << 'SARIF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [{"tool": {"driver": {"name": "osv-scanner", "version": "2.3.5", "rules": [{"id": "GHSA-1234-5678-abcd", "shortDescription": {"text": "Test vulnerability"}}]}}, "results": [{"ruleId": "GHSA-1234-5678-abcd", "level": "error", "message": {"text": "Package 'foo@1.0.0' is vulnerable to 'GHSA-1234-5678-abcd'."}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "package-lock.json"}, "region": {"startLine": 1}}}]}]}]
}
SARIF
        fi
        exit 1
        ;;
    real-findings)
        if [[ "$format" == "sarif" ]]; then
            cp "$OSV_REAL_SARIF" "$output_file"
        fi
        exit 1
        ;;
    no-sources)
        exit 128
        ;;
    error)
        exit 2
        ;;
    bad-json)
        if [[ "$format" == "sarif" ]]; then
            printf 'not valid json{{{\n' > "$output_file"
        fi
        exit 0
        ;;
esac
MOCK
    chmod +x "$MOCK_BIN/osv-scanner"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    cd "$ORIG_DIR" || true
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# Helper: write a SARIF fixture to $1 with a single rule of the given
# CVSS score, one result against $2 (uri). Used by the severity-bucket
# tests below to keep each test body short.
write_sarif_with_severity() {
    local out="$1" severity="$2" rule_id="${3:-CVE-EXAMPLE-1}"
    cat > "$out" <<SARIF
{
  "version": "2.1.0",
  "runs": [{
    "tool": {"driver": {"name": "osv-scanner", "rules": [
      {"id": "$rule_id", "properties": {"security-severity": "$severity"}}
    ]}},
    "results": [{
      "ruleId": "$rule_id",
      "level": "warning",
      "message": {"text": "Package 'lib@1.0.0' is vulnerable to '$rule_id'."},
      "locations": [{"physicalLocation": {"artifactLocation": {"uri": "file:///path/to/pkg"}}}]
    }]
  }]
}
SARIF
}

# --- render_md.sh: direct behavioral tests --------------------------------

@test "render_md: empty SARIF -> 'No known vulnerabilities'" {
    cat > "$TMP_DIR/in.sarif" <<'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"osv-scanner"}},"results":[]}]}
SARIF
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No known vulnerabilities"* ]]
}

@test "render_md: CVSS 9.5 renders as CRITICAL" {
    write_sarif_with_severity "$TMP_DIR/in.sarif" "9.5"
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| CRITICAL |"* ]]
}

@test "render_md: CVSS 7.5 renders as HIGH" {
    write_sarif_with_severity "$TMP_DIR/in.sarif" "7.5"
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| HIGH |"* ]]
    [[ "$output" != *"| MEDIUM |"* ]]
}

@test "render_md: CVSS 5.0 renders as MEDIUM" {
    write_sarif_with_severity "$TMP_DIR/in.sarif" "5.0"
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| MEDIUM |"* ]]
}

@test "render_md: CVSS 2.0 renders as LOW" {
    write_sarif_with_severity "$TMP_DIR/in.sarif" "2.0"
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| LOW |"* ]]
}

@test "render_md: missing security-severity renders as UNKNOWN" {
    cat > "$TMP_DIR/in.sarif" <<'SARIF'
{
  "version": "2.1.0",
  "runs": [{
    "tool": {"driver": {"name": "osv-scanner", "rules": [{"id": "R1"}]}},
    "results": [{"ruleId": "R1", "message": {"text": "Package 'p@1' is vulnerable to 'R1'."},
                 "locations": [{"physicalLocation": {"artifactLocation": {"uri": "p"}}}]}]
  }]
}
SARIF
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| UNKNOWN |"* ]]
}

@test "render_md: dedupes results by ruleId" {
    # osv emits one result per (vuln, lockfile-location). The renderer
    # must collapse them to one row per unique vulnerability.
    cat > "$TMP_DIR/in.sarif" <<'SARIF'
{
  "version": "2.1.0",
  "runs": [{
    "tool": {"driver": {"name": "osv-scanner", "rules": [
      {"id": "CVE-DUPE", "properties": {"security-severity": "7.5"}}
    ]}},
    "results": [
      {"ruleId": "CVE-DUPE", "message": {"text": "Package 'a@1' is vulnerable to 'CVE-DUPE'."},
       "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a/lock"}}}]},
      {"ruleId": "CVE-DUPE", "message": {"text": "Package 'a@1' is vulnerable to 'CVE-DUPE'."},
       "locations": [{"physicalLocation": {"artifactLocation": {"uri": "b/lock"}}}]},
      {"ruleId": "CVE-DUPE", "message": {"text": "Package 'a@1' is vulnerable to 'CVE-DUPE'."},
       "locations": [{"physicalLocation": {"artifactLocation": {"uri": "c/lock"}}}]}
    ]
  }]
}
SARIF
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    rows=$(printf '%s\n' "$output" | grep -cE '^\| (CRITICAL|HIGH|MEDIUM|LOW|UNKNOWN) \|')
    [ "$rows" -eq 1 ]
}

@test "render_md: strips file:// prefix from locations" {
    write_sarif_with_severity "$TMP_DIR/in.sarif" "5.0"
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" != *"file://"* ]]
    [[ "$output" == *"/path/to/pkg"* ]]
}

@test "render_md: extracts fixed versions from rule.help.markdown" {
    cat > "$TMP_DIR/in.sarif" <<'SARIF'
{
  "version": "2.1.0",
  "runs": [{
    "tool": {"driver": {"name": "osv-scanner", "rules": [{
      "id": "CVE-FIX",
      "properties": {"security-severity": "7.5"},
      "help": {"markdown": "Some preamble.\n\n### Fixed Versions\n\n| Vulnerability ID | Package Name | Fixed Version |\n| --- | --- | --- |\n| GHSA-aaaa-bbbb-cccc | leftpad | 1.2.3 |\n\nMore preamble after.\n"}
    }]}},
    "results": [{"ruleId": "CVE-FIX",
                 "message": {"text": "Package 'leftpad@1.0.0' is vulnerable to 'CVE-FIX'."},
                 "locations": [{"physicalLocation": {"artifactLocation": {"uri": "p"}}}]}]
  }]
}
SARIF
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"leftpad@1.2.3"* ]]
}

@test "render_md: missing fixed-versions section renders em-dash" {
    write_sarif_with_severity "$TMP_DIR/in.sarif" "5.0"
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| — |"* ]]
}

@test "render_md: missing file exits 1" {
    run "$RENDER" "$TMP_DIR/does-not-exist.sarif"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SARIF file not found"* ]]
}

@test "render_md: invalid JSON exits 2" {
    printf 'not valid json{{{\n' > "$TMP_DIR/in.sarif"
    run "$RENDER" "$TMP_DIR/in.sarif"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid JSON"* ]]
}

@test "render_md: usage error on missing arg" {
    run "$RENDER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "render_md: real osv fixture renders count-parity rows" {
    run "$RENDER" "$REAL_FIXTURE"
    [ "$status" -eq 0 ]
    unique_rules=$(jq -r '[.runs[].results[].ruleId] | unique | length' "$REAL_FIXTURE")
    rows=$(printf '%s\n' "$output" | grep -cE '^\| (CRITICAL|HIGH|MEDIUM|LOW|UNKNOWN) \|')
    [ "$rows" -eq "$unique_rules" ]
    # CVE-2022-24713 has CVSS 7.5 in the fixture; must render as HIGH.
    [[ "$output" == *"HIGH"* ]]
    [[ "$output" == *"CVE-2022-24713"* ]]
    [[ "$output" == *"CVE-2021-3121"* ]]
    # Fixed-versions extraction from upstream help.markdown.
    [[ "$output" == *"regex@1.5.5"* ]]
}

# --- adapter.sh: end-to-end through PATH-shimmed osv-scanner --------------

@test "osv adapter: produces SARIF with no findings (exit 0)" {
    export OSV_MOCK_MODE="clean"
    run "$ADAPTER" "$TMP_DIR/src" "$TMP_DIR/output"
    [ "$status" -eq 0 ]
    [ -f "$TMP_DIR/output/output.sarif" ]
    jq empty "$TMP_DIR/output/output.sarif"
    [ "$(jq '[.runs[].results[]] | length' "$TMP_DIR/output/output.sarif")" -eq 0 ]
}

@test "osv adapter: produces SARIF with findings (exit 1)" {
    export OSV_MOCK_MODE="findings"
    run "$ADAPTER" "$TMP_DIR/src" "$TMP_DIR/output"
    [ "$status" -eq 1 ]
    [ -f "$TMP_DIR/output/output.sarif" ]
    [ "$(jq '[.runs[].results[]] | length' "$TMP_DIR/output/output.sarif")" -gt 0 ]
}

@test "osv adapter: handles no package sources (exit 0, empty SARIF)" {
    export OSV_MOCK_MODE="no-sources"
    run "$ADAPTER" "$TMP_DIR/src" "$TMP_DIR/output"
    [ "$status" -eq 0 ]
    [ -f "$TMP_DIR/output/output.sarif" ]
    jq empty "$TMP_DIR/output/output.sarif"
    [ "$(jq '[.runs[].results[]] | length' "$TMP_DIR/output/output.sarif")" -eq 0 ]
}

@test "osv adapter: tool error produces exit 2" {
    export OSV_MOCK_MODE="error"
    run "$ADAPTER" "$TMP_DIR/src" "$TMP_DIR/output"
    [ "$status" -eq 2 ]
}

@test "osv adapter: invalid JSON SARIF produces exit 2" {
    export OSV_MOCK_MODE="bad-json"
    run "$ADAPTER" "$TMP_DIR/src" "$TMP_DIR/output"
    [ "$status" -eq 2 ]
}

@test "osv adapter: requires 2 arguments" {
    run "$ADAPTER" "$TMP_DIR/src"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]
}

@test "osv adapter: fails if src_dir does not exist" {
    run "$ADAPTER" "/nonexistent" "$TMP_DIR/output"
    [ "$status" -eq 2 ]
}

@test "osv adapter: fails if output_dir does not exist" {
    run "$ADAPTER" "$TMP_DIR/src" "/nonexistent"
    [ "$status" -eq 2 ]
}

@test "osv adapter: clean scan produces non-empty output.md" {
    export OSV_MOCK_MODE="clean"
    run "$ADAPTER" "$TMP_DIR/src" "$TMP_DIR/output"
    [ "$status" -eq 0 ]
    [ -s "$TMP_DIR/output/output.md" ]
    grep -qi "no known vulnerabilities" "$TMP_DIR/output/output.md"
}

# Regression test for #197: SARIF and the markdown summary must agree.
# The old adapter ran osv-scanner twice (once for SARIF, once for
# markdown) and the markdown formatter under-reported, producing
# "SARIF=N, MD=0". Now MD is rendered from the SARIF directly.
@test "osv adapter: SARIF and MD agree on finding count (real osv fixture)" {
    export OSV_MOCK_MODE="real-findings"
    export OSV_REAL_SARIF="$REAL_FIXTURE"
    run "$ADAPTER" "$TMP_DIR/src" "$TMP_DIR/output"
    [ "$status" -eq 1 ]
    unique_rules=$(jq -r '[.runs[].results[].ruleId] | unique | length' \
        "$TMP_DIR/output/output.sarif")
    md_rows=$(grep -cE '^\| (CRITICAL|HIGH|MEDIUM|LOW|UNKNOWN) \|' \
        "$TMP_DIR/output/output.md")
    [ "$md_rows" -eq "$unique_rules" ]
}

# --- osv e2e: real osv-scanner against a vulnerable manifest --------------

# Drives the full pipeline with the real osv-scanner binary against a
# fixture pinned to a known-vulnerable package version (CVE-2021-3121
# against github.com/gogo/protobuf <1.3.2 — deterministic under network
# access). Skipped when osv-scanner isn't on PATH or osv.dev is
# unreachable (sandboxed dev environments); CI wires the test up in a
# dedicated osv-e2e job in .github/workflows/test.yml so the assertions
# actually run on every PR.
@test "osv e2e: real osv-scanner produces consistent SARIF + MD" {
    if ! command -v osv-scanner >/dev/null 2>&1 || \
       [[ "$(osv-scanner --version 2>&1 | head -n1)" == *"-mock"* ]]; then
        # The shim is still on PATH (or no osv-scanner installed).
        # Remove the shim and re-check.
        export PATH="${PATH#"$MOCK_BIN":}"
    fi
    if ! command -v osv-scanner >/dev/null 2>&1; then
        skip_or_fail "osv-scanner not on PATH; install via tools/osv/install.sh first"
    fi

    cp "$ORIG_DIR/tools/osv/testdata/vulnerable_go.mod" "$TMP_DIR/src/go.mod"

    run "$ADAPTER" "$TMP_DIR/src" "$TMP_DIR/output"
    rc=$status

    # osv.dev API unreachable (sandbox / offline): the adapter returns
    # exit 2 with no SARIF written, or exit 0 with an empty SARIF. In
    # either case skip — there's nothing to assert about the pipeline
    # because osv-scanner couldn't enrich the manifest.
    if [[ ! -s "$TMP_DIR/output/output.sarif" ]]; then
        skip_or_fail "osv-scanner did not produce SARIF (likely network-restricted)"
    fi
    n=$(jq '[.runs[].results[]] | length' "$TMP_DIR/output/output.sarif")
    if [[ "$n" -eq 0 ]]; then
        skip_or_fail "osv-scanner produced 0 results (likely offline or no advisories for fixture)"
    fi

    [ "$rc" -eq 1 ]                              # findings present
    [ -s "$TMP_DIR/output/output.md" ]

    # The #197 invariant: SARIF and MD must agree on unique-vuln count.
    unique_rules=$(jq -r '[.runs[].results[].ruleId] | unique | length' \
        "$TMP_DIR/output/output.sarif")
    md_rows=$(grep -cE '^\| (CRITICAL|HIGH|MEDIUM|LOW|UNKNOWN) \|' \
        "$TMP_DIR/output/output.md")
    [ "$md_rows" -eq "$unique_rules" ]

    # And no file:// prefix leaked into the summary.
    if grep -q "file://" "$TMP_DIR/output/output.md"; then return 1; fi

    # Deterministic content check: the fixture pins gogo/protobuf v1.3.1
    # which has had CVE-2021-3121 published since 2021. If this stops
    # appearing, either the fixture, osv.dev, or the renderer has drifted —
    # all worth a hard failure rather than a silent green.
    grep -q "CVE-2021-3121" "$TMP_DIR/output/output.md"
}

# --- install.sh: go-module install tests -----------------------------------
# osv-scanner installs from tools/go.mod's tool directive (DEP_MGMT branch
# 1); integrity is go.sum/sum.golang.org, freshness is Dependabot. These
# tests are hermetic: `go list -m` reads go.mod locally, no network.

@test "osv install: parses" {
    run bash -n "$INSTALL"
    [ "$status" -eq 0 ]
}

@test "osv install: pins GOPROXY and GOSUMDB at the install site" {
    grep -q 'export GOPROXY="https://proxy.golang.org,direct"' "$INSTALL"
    grep -q 'export GOSUMDB="sum.golang.org"' "$INSTALL"
}

@test "osv install: builds from tools/go.mod, version single-sourced there" {
    # No hardcoded version: the pin lives in go.mod (Dependabot bumps it),
    # and the install resolves it with `go list -m`.
    grep -q 'go -C "$TOOLS_DIR" install "${TOOL_MODULE}/cmd/osv-scanner"' "$INSTALL"
    grep -q "go -C \"\$TOOLS_DIR\" list -m" "$INSTALL"
    run grep -E 'VERSION="[0-9]' "$INSTALL"
    [ "$status" -ne 0 ]
}

@test "osv install: go.mod pins the osv-scanner tool directive" {
    grep -q 'github.com/google/osv-scanner/v2/cmd/osv-scanner' "$ORIG_DIR/tools/go.mod"
}

@test "osv install: skips if correct version already installed" {
    # The mock's version is derived from go.mod so a Dependabot bump can't
    # silently turn this hermetic test into a real network `go install`.
    local ver
    ver="$(go -C "$ORIG_DIR/tools" list -m -f '{{.Version}}' github.com/google/osv-scanner/v2)"
    mkdir -p "$TMP_DIR/install_bin"
    printf '#!/bin/bash\nprintf "osv-scanner version: %s\\n"\n' "${ver#v}" \
        > "$TMP_DIR/install_bin/osv-scanner"
    chmod +x "$TMP_DIR/install_bin/osv-scanner"
    WRANGLE_BIN_DIR="$TMP_DIR/install_bin" run "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

@test "osv install: a different installed version is not mistaken for the pin" {
    # Anchored compare: 2.3.50 must NOT satisfy a 2.3.5 pin. The install
    # then proceeds — and is cut off by the PATH-stripped go shim below,
    # keeping the test hermetic.
    mkdir -p "$TMP_DIR/wrong_bin"
    printf '#!/bin/bash\nprintf "osv-scanner version: 99.99.99\\n"\n' \
        > "$TMP_DIR/wrong_bin/osv-scanner"
    chmod +x "$TMP_DIR/wrong_bin/osv-scanner"
    cat > "$TMP_DIR/wrong_bin/go" <<'SHIM'
#!/bin/bash
# go shim: answer `list -m` from the real go, refuse `install` so the
# test never reaches the network.
if [[ "$*" == *" list "* ]]; then exec /usr/local/go/bin/go "$@"; fi
exit 1
SHIM
    chmod +x "$TMP_DIR/wrong_bin/go"
    WRANGLE_BIN_DIR="$TMP_DIR/wrong_bin" PATH="$TMP_DIR/wrong_bin:$PATH" run "$INSTALL"
    [ "$status" -ne 0 ]
    [[ "$output" != *"already installed"* ]]
}
