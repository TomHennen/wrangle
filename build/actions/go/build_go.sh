#!/bin/bash
# Runs the Go pre-build pipeline: gofmt sanity check, go vet, go test,
# and govulncheck (reachable-vuln scan). Goreleaser itself runs from
# action.yml via goreleaser/goreleaser-action — keeping that as a
# pinned `uses:` step is wrangle convention; this script handles the
# toolchain-level checks that must succeed before goreleaser starts.
#
# Why this set:
#   - gofmt: Go's formatting tool. `go build` does NOT enforce formatting;
#     code with broken gofmt will compile and release through wrangle
#     unchallenged unless we explicitly check. `gofmt -l .` lists files
#     that would change under gofmt; non-empty output → fail. Cheap
#     toolchain-bundled gate until source-stage lint lands (#194).
#   - go vet: ships with the toolchain, catches suspicious constructs
#     (shadowed vars, printf arg mismatches, unreachable code). Free.
#   - go test ./...: required by the SPEC. Tests must pass before
#     wrangle's build action declares success.
#   - govulncheck: callgraph-based vuln scan from golang.org/x/vuln.
#     Reports vulnerabilities actually reachable from the project's code
#     (lower false-positive rate than OSV against go.sum, which catches
#     every vulnerable transitive dep regardless of reachability).
#     Complementary to OSV-Scanner (which actions/scan runs against
#     go.sum as a source-stage check). Verification: go install relies
#     on sum.golang.org's Trillian-backed Merkle log over go.sum-shaped
#     lines for module integrity, the same trust root that powers
#     `go install <module>@<version>` everywhere.
#
# Failure semantics:
#   - gofmt/vet/test failures fail the build (these are quality gates).
#   - govulncheck findings (reachable vulns) are INFORMATIONAL: written
#     to the metadata artifact and surfaced in the step summary, but do
#     NOT fail the build. This matches OSV-Scanner's posture in
#     actions/scan (also informational by default). Two reasons for
#     this choice: (1) stdlib reachability findings are common and
#     would force every adopter to chase Go patch releases on the same
#     cadence wrangle bumps its own goreleaser pin, which is a real
#     maintenance burden for a property orthogonal to the build's
#     correctness; (2) consumers of the L3 attestation can re-scan the
#     released bytes themselves — the SBOM and the source tree are
#     enough for an out-of-band govulncheck run. Adopters who want a
#     blocking gate can wire govulncheck in their own preflight or
#     opt into the same posture in a future wrangle input.
#
# Output: writes govulncheck JSON to $METADATA_DIR/govulncheck.json so
# adopters can see what was scanned without re-running.
#
# Usage: build/actions/go/build_go.sh <path> <metadata_dir> <govulncheck_version>

set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s <path> <metadata_dir> <govulncheck_version>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
METADATA_DIR="$2"
GOVULNCHECK_VERSION="$3"

# Absolute paths captured BEFORE the cd so the metadata write below
# resolves to the workspace root, not the project subdir.
METADATA_DIR_ABS="$(cd "$(dirname "$METADATA_DIR")" && pwd)/$(basename "$METADATA_DIR")"

cd "$INPUT_PATH"

printf '== gofmt check ==\n'
# `gofmt -l .` lists files that would change. Capture; if non-empty,
# print and exit. Doesn't fail the build via gofmt's exit code (it
# returns 0 even when files would change), so we drive the failure
# from the listed-files count.
unformatted="$(gofmt -l . 2>&1 || true)"
if [[ -n "$unformatted" ]]; then
    printf 'Error: the following files are not gofmt-clean:\n'
    printf '%s\n' "$unformatted"
    # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
    printf 'Run `gofmt -w .` locally to fix, then commit.\n'
    exit 1
fi
printf 'gofmt: all files are formatted.\n'

printf '\n== go vet ==\n'
go vet ./...
printf 'go vet: passed.\n'

printf '\n== go test ./... ==\n'
# -race adds overhead but catches data races; mandatory on every
# wrangle Go build. Adopters who absolutely cannot afford -race
# (e.g., CGo + a runtime the race detector doesn't support) can
# fork until we expose a flag.
go test -race ./...
printf 'go test: passed.\n'

printf '\n== govulncheck ==\n'
# Pinned version installed via `go install` (sum.golang.org-verified).
# Installed into the workspace's GOBIN so the binary is gone after the
# job — no PATH pollution outside this run.
GOBIN="$(go env GOBIN)"
if [[ -z "$GOBIN" ]]; then
    GOBIN="$(go env GOPATH)/bin"
fi
go install "golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}"

mkdir -p "$METADATA_DIR_ABS"
GOVULN_OUT="$METADATA_DIR_ABS/govulncheck.json"

# govulncheck -json always exits 0 when the scan completes successfully
# (findings or not); non-zero from -json means a tool error (network,
# infra). Findings are detected by parsing the JSON for "finding"
# entries. We deliberately do NOT block the build on findings (see
# header comment) — only on tool errors.
set +e
"$GOBIN/govulncheck" -json ./... > "$GOVULN_OUT"
status=$?
set -e

if (( status != 0 )); then
    printf 'govulncheck: tool error (exit %d). JSON output: %s\n' "$status" "$GOVULN_OUT" >&2
    exit "$status"
fi

# Each finding emits a JSON object containing a `"finding"` key in
# govulncheck's -json stream. Count them; report a summary.
findings="$(grep -c '"finding"' "$GOVULN_OUT" 2>/dev/null || true)"
if [[ -z "$findings" || "$findings" == "0" ]]; then
    printf 'govulncheck: no reachable vulnerabilities.\n'
else
    printf 'govulncheck: %s reachable vulnerability finding(s) (informational; not failing the build).\n' "$findings"
    printf 'JSON output: %s\n' "$GOVULN_OUT"
    # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
    printf 'Re-run locally with `govulncheck ./...` for human-readable findings.\n'
fi
