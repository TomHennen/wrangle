# Act-Based Local Action Testing — Specification

## Overview

Wrangle ships composite actions and reusable workflows that adopters call from their own repos. The existing test layers (`actionlint`, `shellcheck`, `bats`) verify that the YAML is well-formed and that shell helpers behave correctly, but they don't exercise the actions or workflows end-to-end — they don't catch failures in step wiring, env propagation, local action resolution, input validation, or the sequence of steps a real GitHub Actions runner would execute.

Act-based testing fills that gap by running wrangle's reusable workflows under [`nektos/act`](https://github.com/nektos/act) in the test environment, so composite-action and workflow-level failures are caught before they ship.

This spec describes **what** should be tested via act, **how**, and — critically — what must not be. Act has significant gaps in its GitHub Actions emulation; running tests outside those gaps is what makes act useful here, and running tests inside them is what would make it a net-negative source of flake.

## Design principles

### Prefer the reusable workflow as the test target

Adopters call the reusable workflow (`.github/workflows/check_source_change.yml`, `.github/workflows/build_shell.yml`). That's the contract wrangle ships. Testing through the reusable workflow is strictly stronger coverage than testing the composite action directly: it exercises workflow-level inputs, permissions, secrets forwarding, and the `workflow_call` interface that adopters actually use.

The default test target is therefore the **reusable workflow**, invoked from a minimal caller workflow. The composite action is exercised transitively.

**Composite-action tests are allowed** when they cover a path the reusable workflow test cannot reach. Legitimate reasons:

- The composite action has inputs that the reusable workflow does not expose (or hardcodes a default for), and those inputs have non-trivial behavior.
- The composite has conditional logic whose branches would require constructing workflow-input combinations that are awkward or impossible.
- An error path is easier to trigger by calling the composite directly than by constructing the workflow state that would provoke it.

Every composite-only test **must include a one-line comment at the top** stating which coverage gap it fills — e.g., `# Composite-only: reusable workflow hardcodes mode=release; this exercises mode=debug.` If the reusable workflow test could cover the same ground, the composite-only test is dead weight and should be deleted.

Structural bats tests cover actions that can't run under act at all (see "What act cannot run" below).

### Test against fixtures, not wrangle itself

Running wrangle's reusable workflows against wrangle's own source is tempting but wrong for act tests:

- It couples test outcomes to wrangle's current state. Adding a shell script with a shellcheck warning would break the act test for unrelated reasons.
- It's slow: wrangle's source tree is large enough that scanning it on every test run is an invitation to skip tests.
- It doesn't exercise the error paths (a shellcheck failure, a bats failure, a vulnerable dependency) because wrangle's own code is — ideally — clean.

Act tests run against small, purpose-built fixture projects. Each fixture is the smallest possible project that exercises the behavior under test: one `.sh` file plus one `.bats` file for the shell action's happy path; a fixture with a known shellcheck violation for the failure path; a minimal `Dockerfile` plus one-file context for the container action; etc.

### Co-locate tests and fixtures with the action they exercise

Consistent with wrangle's "everything for one capability lives in one directory" principle (applied elsewhere to `tools/<name>/` and `build/actions/<type>/`), every build action's act tests and fixtures live **inside that action's directory**, not in a central `test/act/` tree. The central `test/act/` directory holds only this spec and cross-cutting infrastructure (the shared `event.json` payload); everything action-specific lives with its action.

Concretely, `build/actions/shell/` owns its own test directory:

```
build/actions/shell/
├── action.yml
├── README.md
├── test.bats                   # structural/unit tests (existing pattern)
└── test/
    ├── caller.yml              # act caller workflow invoking build_shell.yml
    └── fixtures/
        ├── clean/              # happy-path fixture: passes shellcheck + bats
        │   ├── script.sh
        │   └── test.bats
        └── shellcheck-fail/    # failure-path fixture
            └── bad.sh
```

Same pattern for every other build action directory:

```
build/actions/container/
├── action.yml
├── SPEC.md
├── README.md
├── test.bats
└── test/
    ├── caller.yml              # (may be structural-only if act can't run it end-to-end)
    └── fixtures/
        └── minimal/
            ├── Dockerfile
            └── app.sh
```

The `actions/scan/` directory follows the same pattern for the source-scanning reusable workflow (`check_source_change.yml`):

```
actions/scan/
├── action.yml
└── test/
    ├── caller.yml              # invokes check_source_change.yml with tools: "osv"
    └── fixtures/
        ├── mock-osv/           # mock adapter-pattern tool
        │   ├── install.sh
        │   └── adapter.sh
        └── source-clean/       # source tree with no vulns (for clean-path assertion)
```

Rules:

- **Fixtures live with their action, not in a central directory.** A shell-project fixture in `build/actions/shell/test/fixtures/` is for shell-action tests only; reusing it for a different action means duplicating (or creating a genuinely cross-cutting fixture under `test/act/fixtures/` — permitted but require a reason).
- **Caller workflows live with their action.** `build/actions/shell/test/caller.yml` invokes `.github/workflows/build_shell.yml`. `actions/scan/test/caller.yml` invokes `.github/workflows/check_source_change.yml`. The Makefile discovers them (see "Discovery" below) rather than hardcoding a central list.
- **Central `test/act/`** keeps only:
  - This `SPEC.md`.
  - `event.json` (shared push event payload — truly cross-cutting).
  - `lib/` for shared assertion helpers if/when any emerge (premature to create now).

### Fixture requirements by build type

Each build action needs fixtures appropriate to the artifacts it produces. At minimum:

| Build type | Clean-path fixture | Failure-path fixture |
|-----------|-------------------|---------------------|
| `shell` | `.sh` file + `.bats` file that both pass | `.sh` file with a shellcheck violation |
| `container` | `Dockerfile` + minimal build context | `Dockerfile` with a build error (optional — act may not reach the build step anyway; see Docker-in-Docker) |
| Source scanning (`actions/scan`) | Small source tree with no vulns + mock osv adapter | Source tree with a known OSV finding + mock osv that returns a finding |
| Future: `npm` | `package.json` + one `.ts`/`.js` file | `package.json` pinning a known-vulnerable version |
| Future: `python` | `pyproject.toml` + one `.py` file | Same with a vulnerable pin |
| Future: `go` | `go.mod` + one `.go` file | Same with a vulnerable pin |

These are minimums. Actions that have interesting conditional behavior (e.g., the shell action's `bats-path` input validation) need additional fixtures to cover each branch.

### Discovery

`make test-actions` discovers act caller workflows by globbing `**/test/caller.yml` under `build/actions/`, `actions/`, and anywhere else wrangle adds actions later. No central registry of test workflows — adding a new build action with its own `test/caller.yml` automatically picks it up.

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
| Reusable workflow invocation, input validation, step sequence, local composite resolution, shell steps, `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`, adapter-pattern tool execution under `run.sh` | Act, end-to-end against a fixture | `<action-dir>/test/caller.yml` + `<action-dir>/test/fixtures/` (co-located per the rules above) |
| Composite actions that need Docker, elevated tokens, or real GitHub API (scorecard, container builder, codeql SARIF upload, upload-artifact) | Structural bats tests that verify `action.yml` shape — SHA-pinned references, expected inputs, expected env vars, expected step names — without executing them | `<action-dir>/test.bats` (alongside existing structural tests) |

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

- **`github/codeql-action/upload-sarif`** — requires real GitHub Advanced Security API. No local stub in act as of this writing ([#2760](https://github.com/nektos/act/issues/2760) open).
- **`actions/upload-artifact@v6` and `@v7`** — broken under act ([#6021](https://github.com/nektos/act/issues/6021) open); authentication errors on blob upload even with act's built-in artifact server. `@v3` fails separately with missing `ACTIONS_RUNTIME_TOKEN` ([#1929](https://github.com/nektos/act/issues/1929)).
- **`ossf/scorecard-action`** — needs Docker and elevated `GITHUB_TOKEN` scopes (`admin:repo_hook`, `public_repo`) that act's default token does not carry.
- **`zizmorcore/zizmor-action` with `advanced-security: true`** — the action is hard-wired to attempt SARIF upload, which fails for the same reason as `codeql-action/upload-sarif`.
- **Composite action step output propagation to the calling workflow** — act bug ([#2184](https://github.com/nektos/act/issues/2184), [#2697](https://github.com/nektos/act/issues/2697) — both open). Outputs declared on composite actions may not reach the caller. Act tests MUST NOT rely on outputs propagated from composite action to caller; assert on filesystem state or step summary contents instead.
- **`INPUT_*` env var scoping inside composites** — act leaks `INPUT_*` to nested steps ([#2874](https://github.com/nektos/act/issues/2874) open). Act tests MUST NOT assert on `INPUT_*` values inside composite action steps.

### Docker-in-Docker and the container builder

`docker/setup-buildx-action` and `docker/build-push-action` have a more nuanced status than the others:

- **On GitHub-hosted Linux runners, they generally work.** Act doesn't do true Docker-in-Docker; it mounts the host's `/var/run/docker.sock` into the workflow container, so `docker` commands talk back to the host daemon. On stock `ubuntu-latest` with a working Docker install, this is reliable.
- **On dev laptops, they're unreliable** and failure modes depend on the host Docker runtime: Colima on macOS M-series ([#5967](https://github.com/nektos/act/issues/5967)), Docker in WSL2 ([#5870](https://github.com/nektos/act/issues/5870)), and buildx-specific bugs ([#5896](https://github.com/nektos/act/issues/5896)) all have open issues.

However, **DinD is not the only blocker for testing the container builder via act**. Even if DinD works, the container builder action depends on:

- `cache-from: type=gha` / `cache-to: type=gha` — needs GitHub Actions cache API; act's support is on the same fragile artifact-server path that blocks `upload-artifact`.
- `push: true` — pushes an image to a real registry. Test-time options (actually push to ghcr.io, or set up a local registry fixture) both have serious downsides.
- Cosign keyless signing — needs a real GitHub Actions OIDC token that act cannot mint.
- SLSA L3 provenance — generated by a separate reusable workflow (`slsa-github-generator`) that requires its own isolated GHA runtime and can't run under act at all.

The container builder therefore gets **structural bats tests only**, regardless of whether DinD works in the test environment. The right coverage for the container builder is real CI against a staging image repository, not act.

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

This is the strategy for unavoidable hostile steps. Between strategies 1 and 2, every act-hostile step in a wrangle-owned action should be covered — there is no third strategy because allowing the job to fail at a "tail" hostile step would mask regressions in earlier steps and defeat the purpose of the test.

### Not allowed

- `continue-on-error: true` on the whole action under test. This turns a real test into a no-op.
- Copying the action's shell into the test workflow and running it there. This tests the copy, not the action.
- Conditionals based on `github.actor == 'nektos/act'` or workspace introspection. Use the documented `env.ACT` variable.

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

1. **`actions/scan/test/caller.yml`** — invokes `check_source_change.yml` with `tools: "osv"` and the `mock-osv` fixture, asserting that SARIF appears at the expected path and the step summary contains expected content. This is the primary adopter entry point for source scanning.
2. **`build/actions/shell/test/caller.yml`** — invokes `build_shell.yml` against the `clean` fixture, asserting the action exits 0. (Optional second test invoking against `shellcheck-fail` asserting a non-zero exit — deferred if it complicates the runner setup.)
3. **Structural bats tests** covering `actions/scan/action.yml`, `tools/scorecard/action.yml`, `tools/zizmor/action.yml`, `build/actions/shell/action.yml`, `build/actions/container/action.yml`, and the reusable workflows that wrap them. Each test asserts SHA pinning, expected step names, expected inputs, and (where applicable) the presence of the `env.ACT` gates described above. Structural tests live in each action's existing `test.bats` (or a new `test.bats` if the directory doesn't have one yet) — not in a central file.

`build_and_publish_container.yml` is deferred until its composite action is implemented (per `build/actions/container/SPEC.md`, the action is still partial). When the implementation lands, act still cannot run it end-to-end — not just because of Docker-in-Docker, but because of GHA cache, registry push, Cosign OIDC, and the SLSA provenance generator (see "Docker-in-Docker and the container builder" above). It gets structural bats tests only. Real end-to-end coverage for the container builder is real CI against a staging image repository, which is out of scope for this spec.

## Known limitations

- **Act lags real GitHub Actions.** New GitHub Actions features may land in production runners before act supports them. When that happens, the affected reusable workflow drops to structural-bats-only coverage until act catches up.
- **Composite action output propagation is unreliable under act.** Tests assert on filesystem state, not on propagated step outputs. This is a permanent workaround, not a temporary one.
- **Act's `ubuntu-latest` image is not a perfect match for GitHub's.** Differences in pre-installed tools, apt package versions, and base images can cause tests to pass locally but fail in CI (or vice versa). Fixtures and test assertions must not rely on anything beyond what wrangle's action explicitly installs.
