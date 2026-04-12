# Act-Based Local Action Testing — Specification

## Overview

Wrangle ships composite actions and reusable workflows that adopters call from their own repos. The existing test layers (`actionlint`, `shellcheck`, `bats`) verify that the YAML is well-formed and that shell helpers behave correctly, but they don't exercise the actions or workflows end-to-end — they don't catch failures in step wiring, env propagation, local action resolution, input validation, or the sequence of steps a real GitHub Actions runner would execute.

Act-based testing fills that gap by running wrangle's reusable workflows under [`nektos/act`](https://github.com/nektos/act) in the test environment, so composite-action and workflow-level failures are caught before they ship.

This spec describes **what** should be tested via act, **how**, and — critically — what must not be. Act has significant gaps in its GitHub Actions emulation; running tests outside those gaps is what makes act useful here, and running tests inside them is what would make it a net-negative source of flake.

## Design principles

### Test the reusable workflow, not the composite action

Adopters call the reusable workflow (`.github/workflows/check_source_change.yml`, `.github/workflows/build_shell.yml`). That's the contract wrangle ships. Testing the underlying composite action (`actions/scan/action.yml`, `build/actions/shell/action.yml`) directly is strictly weaker coverage: it skips workflow-level inputs, permissions, and the `workflow_call` interface that adopters actually use.

Every act test targets a **reusable workflow**, invoked from a minimal caller workflow defined under `test/act/`. The composite action is exercised transitively. Structural bats tests cover composite actions that can't run under act at all (see "What act cannot run" below).

### Test against fixtures, not wrangle itself

Running wrangle's reusable workflows against wrangle's own source is tempting but wrong for act tests:

- It couples test outcomes to wrangle's current state. Adding a shell script with a shellcheck warning would break the act test for unrelated reasons.
- It's slow: wrangle's source tree is large enough that scanning it on every test run is an invitation to skip tests.
- It doesn't exercise the error paths (a shellcheck failure, a bats failure, a vulnerable dependency) because wrangle's own code is — ideally — clean.

Act tests run against small, purpose-built fixture projects under `test/act/fixtures/`. Each fixture is the smallest possible project that exercises the behavior under test: one `.sh` file plus one `.bats` file for the shell action's happy path; a fixture with a known shellcheck violation for the failure path; etc.

### Tests must exercise the action, not bypass it

A test that invokes `uses: ./build/actions/shell` with `continue-on-error: true` and then runs `bats` directly in the next step is not testing the shell action — it's testing act and bats. Every act test MUST:

1. Invoke the reusable workflow under test via `uses:` without `continue-on-error`.
2. Fail the job if the workflow fails.
3. Assert on observable outputs of the workflow (step summary contents, output files, job status) — not on side-channel operations the test itself performs.

If a step inside the reusable workflow is known to fail under act (see "What act cannot run"), the fix is **not** to add `continue-on-error` around the whole action. The fix is one of the strategies in "Handling act-hostile steps" below.

### Two-track coverage

Act runs what act can run. Everything else gets a structural bats test.

| What | How tested | Where |
|------|-----------|-------|
| Reusable workflow invocation, input validation, step sequence, local composite resolution, shell steps, `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`, adapter-pattern tool execution under `run.sh` | Act, end-to-end against a fixture | `test/act/` |
| Composite actions that need Docker, elevated tokens, or real GitHub API (scorecard, container builder, codeql SARIF upload, upload-artifact) | Structural bats tests that verify `action.yml` shape — SHA-pinned references, expected inputs, expected env vars, expected step names — without executing them | `test/test_action_structure.bats` |

The two tracks are not substitutes. Act catches step-wiring and env-propagation regressions. Structural tests catch "someone removed the SARIF upload step" or "someone unpinned a SHA." Both are cheap and both fail-fast.

## What act can run

Confirmed to work reliably under act with wrangle's reusable workflows:

- Local composite action resolution (`uses: ./path/to/action`)
- Shell `run:` steps inside composite actions
- `env:` propagation within a composite action
- `GITHUB_OUTPUT` (within a single composite action scope)
- `GITHUB_STEP_SUMMARY` (file created, content writable)
- `github.action_path` for local actions
- `github.workspace`, `github.event_name`, and most `github.*` context
- `workflow_call` invocation with inputs and secrets
- Adapter-pattern tool execution via `run.sh` (shell scripts all the way down)
- `slsa-framework/slsa-verifier/actions/installer` (binary install, no API)
- `actions/checkout` against the local workspace

## What act cannot run

Stated as facts — **do not attempt to work around these in act tests**. Coverage for these paths is structural bats tests, not act tests.

- **`github/codeql-action/upload-sarif`** — requires real GitHub Advanced Security API.
- **`actions/upload-artifact@v7`** — broken under act ([#6021](https://github.com/nektos/act/issues/6021)); authentication errors even with act's built-in artifact server.
- **`docker/setup-buildx-action`, `docker/build-push-action`** — Docker-in-Docker connectivity issues inside act's runner containers.
- **`ossf/scorecard-action`** — needs Docker and elevated `GITHUB_TOKEN` scopes (`admin:repo_hook`, `public_repo`) that act's default token does not carry.
- **`zizmorcore/zizmor-action` with `advanced-security: true`** — the action is hard-wired to attempt SARIF upload, which fails for the same reason as `codeql-action/upload-sarif`.
- **Composite action step output propagation to the calling workflow** — act bug ([#2184](https://github.com/nektos/act/issues/2184), [#2697](https://github.com/nektos/act/issues/2697)); outputs declared on composite actions may not reach the caller. Act tests MUST NOT rely on outputs propagated from composite action to caller; assert on filesystem state or step summary contents instead.
- **`INPUT_*` env var scoping inside composites** — act leaks `INPUT_*` to nested steps ([#2874](https://github.com/nektos/act/issues/2874)). Act tests MUST NOT assert on `INPUT_*` values inside composite action steps.

## Handling act-hostile steps inside a tested workflow

Several of wrangle's reusable workflows — especially `check_source_change.yml` via `actions/scan` — contain steps that cannot run under act (upload-sarif, upload-artifact). The workflow as a whole cannot pass under act unless those steps are dealt with.

The allowed strategies, in order of preference:

### 1. Scope the test inputs so hostile steps don't execute

Where possible, invoke the reusable workflow with inputs that skip hostile paths. For example, `check_source_change.yml` with `tools: "osv"` (adapter-pattern only) avoids invoking `tools/scorecard` and `tools/zizmor` entirely, which eliminates the Docker-in-Docker and `advanced-security: true` problems. This strategy is free — no action-side changes required.

This does not eliminate the always-run hostile steps (`codeql-action/upload-sarif`, `upload-artifact`). Those still need one of the strategies below.

### 2. Gate hostile steps on `env.ACT`

Act sets the environment variable `ACT=true` inside every step it executes. Steps that cannot run under act MAY be guarded with `if: ${{ !env.ACT }}`. This modifies the production action, but it's a well-understood one-line change with a clear purpose.

Rules for `env.ACT` gates:
- Only permitted on steps that are demonstrably incompatible with act (documented in "What act cannot run").
- Gate MUST be on the individual step, not on the whole action or a larger block. A gate that skips multiple steps hides regressions.
- Each gated step gets a comment explaining why: `# Skipped under act: codeql-action/upload-sarif needs real GHAS API`.
- When `nektos/act` fixes the underlying limitation, the gate is removed. Gates are not permanent.

This is the preferred strategy for unavoidable hostile steps.

### 3. Accept tail-failure

If a step near the end of the workflow is hostile (after all the interesting logic has run), the test MAY allow the job to fail on that step and assert on the filesystem state produced by earlier steps. This is more fragile than option 2 — a regression in an earlier step can be masked by the expected tail failure — and is allowed only when option 2 isn't viable.

### Not allowed

- `continue-on-error: true` on the whole action under test. This turns a real test into a no-op.
- Copying the action's shell into the test workflow and running it there. This tests the copy, not the action.
- Conditionals based on `github.actor == 'nektos/act'` or workspace introspection. Use the documented `env.ACT` variable.

## Directory structure

```
test/act/
├── SPEC.md                              # this file
├── event.json                           # minimal push event payload shared across tests
├── workflows/                           # caller workflows that invoke wrangle's reusable workflows
│   ├── test-build-shell.yml             # calls .github/workflows/build_shell.yml
│   └── test-check-source-change.yml     # calls .github/workflows/check_source_change.yml with tools: "osv"
└── fixtures/
    ├── shell-clean/                     # fixture: shell project that passes shellcheck+bats
    │   ├── script.sh
    │   └── test.bats
    ├── shell-shellcheck-fail/           # fixture: shell project with a shellcheck violation (for failure-path tests)
    │   └── bad.sh
    └── mock-osv/                        # fixture: mock osv-scanner tool directory
        ├── install.sh
        └── adapter.sh
```

Each caller workflow under `workflows/` is a GitHub Actions workflow (not an action) that uses `workflow_call` to invoke the wrangle reusable workflow under test, plus assertion steps that verify observable outputs.

## Test workflow conventions

Every act test workflow follows this shape:

```yaml
name: <descriptive name>
on: push  # act fires push by default

jobs:
  <job-name>:
    runs-on: ubuntu-latest
    # ...set up fixture if needed...
    uses: ./.github/workflows/<reusable-workflow>.yml  # the workflow under test
    with:
      <inputs>

  verify:
    needs: <job-name>
    runs-on: ubuntu-latest
    steps:
      - name: Assert on observable outputs
        # check filesystem state, step summary contents, etc.
```

Requirements for every act test workflow:

- `uses:` the reusable workflow under `.github/workflows/`, not a composite action directly.
- No `continue-on-error: true` on the workflow under test.
- A separate `verify` job (or assertion steps after the workflow) that asserts on observable outputs.
- All assertions use `set -euo pipefail` and `printf` (never `echo`) per CLAUDE.md.
- No network calls beyond what the workflow under test performs; fixtures are self-contained.

## Failure contract

An act test fails (job exits non-zero) under any of these conditions:

- The reusable workflow under test fails, unless the failing step is explicitly gated by `env.ACT` per strategy 2 above.
- An assertion step in the verify job fails.
- Required output files are missing.
- Step summary does not contain expected content.

Act tests are deterministic: given the same fixture and workflow, they must always pass or always fail. Any test that is "usually" green is a flake and must be fixed or removed.

## Integration with existing test infrastructure

### Running act tests

- `make test-actions` runs all act-based tests.
- `./test.sh test-actions` runs them in the Docker test container (same as local dev does for `make test`).
- `./test.sh` (default target) runs `test` + `test-actions`. Both must pass for the default target to pass.

### Where act runs

Act spawns Docker containers via the host Docker daemon, so act itself runs on the host, not nested inside the test container. The test container's role is to provide a consistent shell + tool environment for the act invocation; the actual workflow execution happens in containers spawned by act.

This means:
- Local dev needs Docker + the test container to run `./test.sh test-actions`.
- CI (`.github/workflows/test.yml`) already runs on a Docker-enabled runner, so no extra setup.
- Adopters of wrangle do not need act; it's purely a wrangle-development tool.

### CI

`./test.sh` is the single CI entry point; `test-actions` is a target of `./test.sh`. No changes to `.github/workflows/test.yml` are needed when act tests are added or modified.

## What this spec does not cover

- **Unit tests** for shell helpers in `lib/` — those stay as bats tests under `test/lib/`.
- **Tool adapter tests** (e.g., `tools/osv/test.bats`) — those stay as bats tests in the tool's directory.
- **SARIF fixture validation** — stays as bats tests under `test/`.
- **`actionlint` and `shellcheck` runs** — part of `make test`, not `make test-actions`.

Act testing is specifically the layer for exercising composite actions and reusable workflows end-to-end. Other test layers remain.

## Scope for initial implementation

The first cut of act testing MUST cover:

1. `check_source_change.yml` invoked with `tools: "osv"` and a mock osv fixture, asserting that SARIF appears at the expected path and the step summary contains expected content. This is the primary adopter entry point.
2. `build_shell.yml` invoked against the `shell-clean` fixture, asserting the action exits 0. (Optional second test invoking against `shell-shellcheck-fail` asserting a non-zero exit — deferred if it complicates the runner setup.)
3. Structural bats tests covering `actions/scan/action.yml`, `tools/scorecard/action.yml`, `tools/zizmor/action.yml`, `build/actions/shell/action.yml`, and the reusable workflows that wrap them. Each test asserts SHA pinning, expected step names, expected inputs, and (where applicable) the presence of the `env.ACT` gates described above.

`build_and_publish_container.yml` is deferred until its composite action is implemented (per the container builder spec in `build/actions/container/SPEC.md`, the action is still partial). When the implementation lands, act cannot run it end-to-end (Docker-in-Docker); it gets structural bats tests only.

## Known limitations

- **Act lags real GitHub Actions.** New GitHub Actions features may land in production runners before act supports them. When that happens, the affected reusable workflow drops to structural-bats-only coverage until act catches up.
- **Composite action output propagation is unreliable under act.** Tests assert on filesystem state, not on propagated step outputs. This is a permanent workaround, not a temporary one.
- **Act's `ubuntu-latest` image is not a perfect match for GitHub's.** Differences in pre-installed tools, apt package versions, and base images can cause tests to pass locally but fail in CI (or vice versa). Fixtures and test assertions must not rely on anything beyond what wrangle's action explicitly installs.
