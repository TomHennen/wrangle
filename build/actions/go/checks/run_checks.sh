#!/bin/bash
# Runs the Go pre-build quality gates: gofmt format check (with
# auto-skip for generated files), `go vet`, `go test`, and
# `govulncheck` reachable-vuln scan.
#
# Lives in a separate composite from the release-side build steps
# (build/actions/go/release/) so the calling reusable workflow can
# run quality checks with `contents: read` while the release job
# (which invokes goreleaser, the only step that genuinely needs
# `contents: write`) runs with the stronger permission. The cost is
# one extra checkout + setup-go per build; the benefit is that the
# `go test` step — which executes arbitrary adopter test code —
# cannot push to the repo even if compromised.
#
# Pure decision functions (`is_generated_file`, `list_unformatted`,
# `count_findings`) live alongside main() so test.bats can source
# this file and call them directly, mirroring
# build/actions/npm/build_and_pack.sh's three-layer pattern (pure
# function tests, behavioral tests against fixture dirs, integration
# tests via PATH-shimmed toolchains).
#
# Failure semantics:
#   - gofmt/vet/test failures fail the build (these are quality gates).
#   - govulncheck findings are INFORMATIONAL: counted, summarized to
#     $GITHUB_STEP_SUMMARY and the JSON written to <metadata_dir>/
#     govulncheck.json, but do NOT fail the build. Matches OSV-Scanner's
#     posture in actions/scan. Reasoning in build/actions/go/SPEC.md
#     "Failure semantics."
#   - govulncheck tool errors (network, infra) still propagate.
#
# Usage: build/actions/go/checks/run_checks.sh <path> <metadata_dir>
#                                              <govulncheck_version>
#                                              <run_race> <run_gofmt>
#
#   path:                 project directory (already validated by
#                         the composite's validate_inputs.sh)
#   metadata_dir:         workspace-relative dir for govulncheck.json
#                         (e.g., metadata/go/_/). MUST exist; caller
#                         creates it.
#   govulncheck_version:  pinned semver (e.g., v1.1.4). Wrangle never
#                         takes `latest`/`main` — see CLAUDE.md
#                         "Supply Chain Discipline."
#   run_race:             "true" → `go test -race`; anything else →
#                         plain `go test`. CGO-disabled builds must
#                         pass "false" because the race detector
#                         requires cgo.
#   run_gofmt:            "true" → run gofmt check (with the
#                         generated-file auto-skip below);
#                         anything else → skip gofmt entirely.

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

# Pure function: returns 0 iff the file carries the standard Go
# generated-code header on its first three lines. Mirrors
# golangci-lint's --skip-files generated-code heuristic. The regex
# matches Go's documented convention exactly:
# https://pkg.go.dev/cmd/go/internal/generate
#
# Args: <file_path>
is_generated_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    head -3 "$file" 2>/dev/null | grep -qE '^// Code generated .* DO NOT EDIT\.$'
}

# Pure function: list files in <project_dir> that are not gofmt-clean,
# EXCLUDING generated files. Prints one filename per line to stdout.
# Empty stdout (no output) means everything is formatted.
#
# Args: <project_dir>
list_unformatted() {
    local path="$1"
    (
        cd "$path"
        # gofmt -l writes filenames to stdout. Stderr (e.g., syntax
        # errors) goes to the step log, not into the filename stream
        # — otherwise an unparseable file would surface here as a
        # confusing "this file is not gofmt-clean" listing its
        # syntax-error line. go vet (run after) catches the syntax
        # error with a clear message.
        gofmt -l . | while read -r f; do
            [[ -n "$f" ]] || continue
            if is_generated_file "$f"; then
                continue
            fi
            printf '%s\n' "$f"
        done
    )
}

# Pure function: count the number of `"finding"` entries in a
# govulncheck -json output file. govulncheck -json emits one JSON
# object per protocol message; each finding object contains the
# `"finding"` key. Count is a grep on the literal string — fine
# because the key only appears in finding records (not in
# descriptive fields).
#
# govulncheck -json ALWAYS exits 0 on a successful scan regardless
# of findings (this was a bug in our first cut where we drove the
# count off the exit code — exit code only signals tool error).
#
# Args: <json_path>
# Prints: integer >= 0
count_findings() {
    local json="$1"
    if [[ ! -f "$json" ]]; then
        printf '0\n'
        return
    fi
    # `grep -c` prints "0" and exits 1 on no matches, prints N and
    # exits 0 on N matches. Either way the count is on stdout, so
    # `|| true` swallows the no-match exit code. Using `|| printf 0`
    # here would double-print on empty input (grep's "0" + our "0").
    grep -c '"finding"' "$json" 2>/dev/null || true
}

# Pure function: install govulncheck via `go install` at the pinned
# version. Idempotent — `go install` is a no-op if the version is
# already on the module cache + GOBIN. Resolves GOBIN explicitly so
# the caller can locate the binary without re-querying.
#
# Args: <version>
# Prints: absolute path to the installed govulncheck binary
install_govulncheck() {
    local version="$1"
    local gobin
    gobin="$(go env GOBIN)"
    if [[ -z "$gobin" ]]; then
        gobin="$(go env GOPATH)/bin"
    fi
    go install "golang.org/x/vuln/cmd/govulncheck@${version}" 1>&2
    printf '%s/govulncheck\n' "$gobin"
}

# --- main orchestrator -----------------------------------------------

main() {
    if [[ $# -ne 5 ]]; then
        printf 'Usage: %s <path> <metadata_dir> <govulncheck_version> <run_race> <run_gofmt>\n' "$0" >&2
        exit 1
    fi

    local input_path="$1"
    local metadata_dir="$2"
    local govulncheck_version="$3"
    local run_race="$4"
    local run_gofmt="$5"

    # Absolute path captured BEFORE the cd so subsequent writes resolve
    # to the workspace root, not the project subdir.
    local metadata_dir_abs
    metadata_dir_abs="$(cd "$(dirname "$metadata_dir")" && pwd)/$(basename "$metadata_dir")"
    mkdir -p "$metadata_dir_abs"

    # --- gofmt -------------------------------------------------------
    if [[ "$run_gofmt" == "true" ]]; then
        printf '== gofmt check ==\n'
        local unformatted
        unformatted="$(list_unformatted "$input_path")"
        if [[ -n "$unformatted" ]]; then
            printf 'Error: the following files are not gofmt-clean:\n'
            printf '%s\n' "$unformatted"
            # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
            printf 'Run `gofmt -w .` locally to fix, then commit.\n'
            # shellcheck disable=SC2016
            printf 'If the file is generated and missing the `// Code generated ... DO NOT EDIT.` header,\n'
            printf 'add that header (Go convention) — wrangle will auto-skip it. Or disable the gofmt\n'
            printf 'check entirely via run-gofmt-check: false on the action input.\n'
            exit 1
        fi
        printf 'gofmt: all files are formatted (generated files auto-skipped).\n'
    else
        printf '== gofmt check ==\nSkipped (run-gofmt-check: false).\n'
    fi

    # --- go vet ------------------------------------------------------
    printf '\n== go vet ==\n'
    ( cd "$input_path" && go vet ./... )
    printf 'go vet: passed.\n'

    # --- go test -----------------------------------------------------
    printf '\n== go test ./... ==\n'
    if [[ "$run_race" == "true" ]]; then
        ( cd "$input_path" && go test -race ./... )
        printf 'go test: passed (with race detector).\n'
    else
        ( cd "$input_path" && go test ./... )
        printf 'go test: passed (race detector skipped via run-race-detector: false).\n'
    fi

    # --- govulncheck -------------------------------------------------
    printf '\n== govulncheck ==\n'
    local govuln_bin govuln_out
    govuln_bin="$(install_govulncheck "$govulncheck_version")"
    govuln_out="$metadata_dir_abs/govulncheck.json"

    # govulncheck -json exits 0 even on findings (findings carried in
    # the JSON, not the exit code); non-zero means a tool error
    # (network, infra). We propagate tool errors but never block on
    # findings.
    set +e
    ( cd "$input_path" && "$govuln_bin" -json ./... ) > "$govuln_out"
    local status=$?
    set -e

    if (( status != 0 )); then
        printf 'govulncheck: tool error (exit %d). JSON output: %s\n' "$status" "$govuln_out" >&2
        exit "$status"
    fi

    local findings
    findings="$(count_findings "$govuln_out")"
    if (( findings == 0 )); then
        printf 'govulncheck: no reachable vulnerabilities.\n'
    else
        printf 'govulncheck: %s reachable vulnerability finding(s) (informational; not failing the build).\n' "$findings"
        printf 'JSON output: %s\n' "$govuln_out"
        # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
        printf 'Re-run locally with `govulncheck ./...` for human-readable findings.\n'
    fi

    # Step summary: surface the finding count where adopters look first
    # (the job page). Visibility issue tracked in #242.
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            printf '## Go quality checks\n\n'
            printf '| Check | Result |\n|---|---|\n'
            if [[ "$run_gofmt" == "true" ]]; then
                printf '| gofmt | passed (generated files auto-skipped) |\n'
            else
                printf '| gofmt | skipped |\n'
            fi
            printf '| go vet | passed |\n'
            if [[ "$run_race" == "true" ]]; then
                printf '| go test | passed (with race detector) |\n'
            else
                printf '| go test | passed |\n'
            fi
            printf '| govulncheck | %s reachable finding(s) — informational |\n' "$findings"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
}

# Sourcing guard: tests source this file to call decision functions
# directly without running the full pipeline.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
