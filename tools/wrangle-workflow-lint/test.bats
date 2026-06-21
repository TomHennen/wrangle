#!/usr/bin/env bats

# Tests for tools/wrangle-workflow-lint/lint.sh — the python3 + PyYAML
# linter for CLAUDE.md GitHub Actions conventions that operate on workflow
# structure (run-block line spans, step-sibling keys) rather than shell AST.
#
# Layout:
#   - One committed fixture per rule under fixtures/ (named *.yml, never
#     action.yml, so zizmor's tools/ scan ignores them — the parser keys
#     off jobs.*.steps / runs.steps, not the filename).
#   - good.yml is the negative fixture — must pass cleanly.
#   - Inline tmp fixtures cover boundaries (exactly 10 lines), folded
#     scalars, env-threaded inputs, and the continue-on-error exception.

setup() {
    ORIG_DIR="$(pwd)"
    LINTER="$ORIG_DIR/tools/wrangle-workflow-lint/lint.sh"
    FIXTURES="$ORIG_DIR/tools/wrangle-workflow-lint/fixtures"
    export ORIG_DIR LINTER FIXTURES

    # Fail loud if no python3 with PyYAML is reachable. The linter is
    # mandatory in CI and in the test image; a silent skip would let a broken
    # image ship green. Mirror lint.sh's interpreter discovery — the managed
    # venv in the image, or a system python3 with PyYAML for local dev.
    if [[ -x /opt/wrangle-workflow-lint/bin/python3 ]]; then
        PY=/opt/wrangle-workflow-lint/bin/python3
    elif command -v python3 >/dev/null 2>&1; then
        PY=python3
    else
        printf 'python3 not on PATH — run via ./test.sh (the Docker image provides it)\n' >&2
        return 1
    fi
    if ! "$PY" -c 'import yaml' >/dev/null 2>&1; then
        printf 'PyYAML not importable — install tools/wrangle-workflow-lint/requirements.txt into a venv (see test/Dockerfile)\n' >&2
        return 1
    fi
}

teardown() {
    cd "$ORIG_DIR" || true
}

# --- Negative fixture --------------------------------------------------------

@test "clean workflow: no violations reported" {
    run "$LINTER" "$FIXTURES/good.yml"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- WWL001 (R1): run-block length cap --------------------------------------

@test "WWL001: oversized workflow run block is reported" {
    run "$LINTER" "$FIXTURES/bad_r1_workflow.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL001"* ]]
}

@test "WWL001: oversized composite (runs.steps) run block is reported" {
    # Pins that the scanner walks runs.steps[], not only jobs.*.steps[].
    run "$LINTER" "$FIXTURES/bad_r1_composite.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL001"* ]]
}

@test "WWL001: a run block of exactly 10 lines passes (boundary)" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    {
        printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n'
        printf '      - run: |\n'
        for i in $(seq 1 10); do printf '          printf "line %s\\n"\n' "$i"; done
    } > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WWL001"* ]]
}

@test "WWL001: a run block of 11 lines fails (boundary)" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    {
        printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n'
        printf '      - run: |\n'
        for i in $(seq 1 11); do printf '          printf "line %s\\n"\n' "$i"; done
    } > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL001"* ]]
}

@test "WWL001: comments and blank lines count toward the cap" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          set -euo pipefail\n          # c\n\n          # c\n\n          # c\n\n          # c\n\n          # c\n\n          printf done\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL001"* ]]
}

@test "WWL001: a short run block is not flagged" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          set -euo pipefail\n          printf done\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WWL001"* ]]
}

# --- WWL002 (R2): expression injection into a run body ----------------------

@test "WWL002: inputs.* interpolated into a run body is reported" {
    run "$LINTER" "$FIXTURES/bad_r2.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL002"* ]]
}

@test "WWL002: an input threaded through env: is not flagged" {
    # The safe pattern: inputs.* appears in env:, referenced as $VAR in the
    # run body. R2 must scan only run: bodies, not env:/with:/if:.
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - env:\n          P: ${{ inputs.path }}\n        run: |\n          set -euo pipefail\n          printf "%%s" "$P"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WWL002"* ]]
}

@test "WWL002: a sibling context ending in 'inputs' is not flagged" {
    # ${{ matrix.inputs }} / ${{ steps.x.outputs.inputs }} are not typed-
    # input interpolations — `inputs` is only a path segment. The rule
    # anchors `inputs` as an expression root, so these must not fire.
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo "${{ matrix.inputs }}"\n      - run: echo "${{ steps.foo.outputs.inputs }}"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WWL002"* ]]
}

@test "WWL002: inputs['x'] bracket access in a run body is reported" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo "${{ inputs['\''x'\''] }}"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL002"* ]]
}

@test "WWL002: github.event.* interpolated into a run body is reported" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo "${{ github.event.issue.title }}"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL002"* ]]
}

@test "WWL002: github.head_ref interpolated into a run body is reported" {
    # The classic pull_request_target injection vector.
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo "${{ github.head_ref }}"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL002"* ]]
}

@test "WWL002: a safe context (github.sha) in a run body is not flagged" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: printf "%%s" "${{ github.sha }}"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WWL002"* ]]
}

# --- WWL003 (R4): continue-on-error on a verification-class step ------------

@test "WWL003: unjustified continue-on-error on a verify step is reported" {
    run "$LINTER" "$FIXTURES/bad_r4.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL003"* ]]
}

@test "WWL003: keyword match on uses: triggers the rule" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: sigstore/cosign-installer@v3\n        continue-on-error: true\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL003"* ]]
}

@test "WWL003: continue-on-error on a non-verification step is not flagged" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - name: Upload artifact\n        uses: actions/upload-artifact@v4\n        continue-on-error: true\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WWL003"* ]]
}

@test "WWL003: a verification step without continue-on-error is not flagged" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - name: Verify provenance\n        run: slsa-verifier verify-artifact x\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WWL003"* ]]
}

@test "WWL003: expression-form continue-on-error (\${{ true }}) is reported" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - name: cosign verify\n        continue-on-error: ${{ true }}\n        run: cosign verify x\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL003"* ]]
}

@test "WWL003: an unnamed inline 'run: ... verify' step is reported (run body in identity)" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: gh attestation verify x\n        continue-on-error: true\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL003"* ]]
}

@test "WWL003: a routine 'run: npm install' is not flagged (install dropped from run set)" {
    # `install` matches a step name/uses but NOT a run body, so package
    # installs do not false-flag.
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm install\n        continue-on-error: true\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WWL003"* ]]
}

@test "WWL003: a trailing inline justification comment exempts it" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - name: verify provenance\n        continue-on-error: true  # advisory in this context\n        run: slsa-verifier verify x\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WWL003"* ]]
}

@test "WWL003: an incidental comment elsewhere in the step does not exempt it" {
    # Tightened (WSL005-style): only a comment bound to the continue-on-error
    # line counts, not an unrelated comment elsewhere in the step.
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - name: verify provenance\n        # TODO: rename this step\n        id: v\n        continue-on-error: true\n        run: slsa-verifier verify x\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL003"* ]]
}

@test "WWL003: a whitespace-only comment is not a justification" {
    # Mirrors WSL005: an empty `#` is not an explanation.
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - name: Verify provenance\n        #\n        continue-on-error: true\n        run: slsa-verifier verify-artifact x\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WWL003"* ]]
}

# --- Tool-error handling -----------------------------------------------------

@test "malformed YAML fails closed (exit 2)" {
    tmp="$(mktemp /tmp/wwl-XXXXXX.yml)"
    printf 'on: push\njobs:\n  b:\n   - bad: [unclosed\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 2 ]
}

# --- Output format -----------------------------------------------------------

@test "output format includes path, line, and rule id" {
    run "$LINTER" "$FIXTURES/bad_r1_workflow.yml"
    [ "$status" -eq 1 ]
    found=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[^:]+:[0-9]+:\ WWL[0-9]+: ]]; then
            found=true
            break
        fi
    done <<< "$output"
    [ "$found" = true ]
}

# --- Dogfood: linter passes on the entire wrangle repo ----------------------

@test "dogfood: workflow-lint passes on the entire wrangle repo (exit 0)" {
    cd "$ORIG_DIR"
    run "$LINTER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- Dockerfile / requirements.txt drift guard ------------------------------
# PyYAML's version lives only in tools/wrangle-workflow-lint/requirements.txt;
# the Dockerfile COPYs that file and installs it with --require-hashes into a
# venv. As with wrangle-shell-lint, requirements.txt IS the sole pinned-version
# source, so drift is impossible by construction and no drift-guard test is
# needed. Hash well-formedness is enforced by pip --require-hashes at image
# build time (a missing hash fails the build), exercised by every ./test.sh run.
