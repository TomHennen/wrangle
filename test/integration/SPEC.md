# Integration Testing — Specification

## Overview

Wrangle's composite actions and reusable workflows are contracts consumed by adopters — external repositories that invoke wrangle via `uses:`. The existing test layers (`actionlint`, `shellcheck`, `bats`, per-action structural tests) verify that wrangle's code is well-formed and has the right shape, but they don't exercise those contracts end-to-end on real GitHub Actions infrastructure. Wrangle's own dogfooding (running `check_source_change.yml` and `build_shell.yml` on wrangle's own PRs) covers two of those workflows against wrangle's own source, but not against an adopter-shaped project, and doesn't cover the container builder or any future build type that wrangle is not itself.

Integration testing fills that gap by running wrangle's reusable workflows against a **companion repository** — a small project wired up the way an adopter would wire it — on every internal wrangle PR. Failures in the companion repo surface as a failed check on the wrangle PR, before merge.

This spec defines how that wiring works, which workflows it covers, and — critically — how it handles the security model so that fork PRs from untrusted contributors cannot abuse the mechanism.

## Design principles

### Test against a real companion repo, not an emulation

The act-based approach tried before this one used an emulator (`nektos/act`) to run wrangle's workflows locally. Emulators are inherently approximate: `upload-sarif` doesn't actually reach the Security tab, `upload-artifact` doesn't reach real storage, Cosign keyless signing needs a real OIDC token act cannot mint, and SLSA L3 provenance requires an isolated reusable-workflow runtime that no emulator reproduces. Tests built on an emulator either avoid those paths (testing the cheap parts) or paper over them with test-only logic in production actions.

Integration testing uses real GitHub-hosted runners, real OIDC, real registries, real Security tab uploads, real artifact storage. The reusable workflow under test does exactly what it would do for a real adopter, and the test fails if and only if a real adopter would see a failure.

### Test the reusable workflow, not the composite action

Adopters call the reusable workflow (`.github/workflows/<name>.yml`). The composite action behind it (`actions/scan/action.yml`, `build/actions/shell/action.yml`) is an implementation detail. Testing through the reusable workflow exercises the real adopter-facing surface — workflow-level inputs, permissions, secrets forwarding, `workflow_call` semantics — that direct composite invocation skips.

Per-action structural bats tests (`<action-dir>/test.bats`) already cover composite-level invariants that don't need a full workflow run. Integration testing layers on top, not underneath.

### Fork PR safety is load-bearing

The dispatch mechanism described below relies on a GitHub Actions property: `pull_request` workflows triggered from forks run without access to the base repo's secrets. The integration-test dispatch requires a secret (a PAT to trigger the companion repo's workflow). Fork PRs do not get that secret, so the dispatch silently fails for them — the companion repo is never triggered by untrusted code.

Everything else about this design flows from that one property. If a future change would weaken it (for example, switching to `pull_request_target` to "get secrets on fork PRs"), the change would have to re-prove the security model from scratch. Changes that do that are prohibited unless they pass a dedicated security review.

### Fixtures are minimal and adopter-shaped

Each build type's fixture in the companion repo is the smallest possible project of that type: a single `.sh` file and one `.bats` test for the shell build type, a minimal `Dockerfile` plus a one-file context for the container builder, etc. Fixtures are sized to exercise the adopter contract, not the tool's internals — the tests are already covered elsewhere.

Fixtures are **real projects**, not mocks. The container fixture builds a real image and pushes it to a real staging location. The scan fixture has real dependencies that real OSV scans can run against. The point of integration testing is to catch things emulation can't; using mocks would reintroduce the emulator's limitations.

## Architecture

Three components, living in two repositories:

| Component | Location | Responsibility |
|-----------|----------|----------------|
| **Dispatch workflow** | `wrangle/.github/workflows/integration-test.yml` | Triggered on every wrangle PR. For PRs from within the wrangle repo, dispatches the companion repo's test workflow, passing the PR's head SHA. Waits for the dispatched run and surfaces its pass/fail status as a check on the PR. |
| **Companion repo** | `tomhennen/wrangle-test` (separate repository) | Small monorepo with one subdirectory per build type (`shell/`, `container/`, `scan/`). One workflow file with one job per build type, each job invoking the corresponding wrangle reusable workflow via `uses: TomHennen/wrangle/.github/workflows/<name>.yml@${{ inputs.wrangle_ref }}`. |
| **Status wait logic** | Inside the dispatch workflow | Polls the GitHub API for the dispatched run's status. Succeeds iff the companion repo run succeeds. |

The companion repo is a single repo with subdirectories, not one repo per build type. Splitting would multiply infrastructure (per-repo secrets, per-repo CI history, per-repo PAT scoping) without any corresponding benefit — each wrangle build type operates on its own subdirectory via `path`/`scan-path`/etc. inputs, so they coexist cleanly.

## Security model

### Threat: drive-by attack via fork PR

An attacker opens a PR from a fork of wrangle containing malicious code — for example, a modified composite action that exfiltrates secrets. If the integration-test workflow ran this code with secrets attached, the attacker would compromise those secrets.

### Defense: GitHub's baseline fork-PR secret exclusion

GitHub Actions has a built-in rule: `pull_request` workflows triggered from forks run **without** access to repository secrets. The integration-test workflow needs a secret (a PAT, `TEST_REPO_PAT`, to trigger `workflow_dispatch` on the companion repo). Fork PRs do not get that secret, so:

- The `TEST_REPO_PAT` environment variable is unset in the dispatch step.
- The `gh workflow run` call fails with an authentication error.
- The integration-test check fails on the fork PR with a clear "integration tests cannot run for fork PRs" message — or the job is skipped entirely via an explicit `if:` guard on `github.event.pull_request.head.repo.full_name == github.repository`.

Either way: **no malicious code from the fork reaches the companion repo**, because the companion repo is never triggered.

### What internal PRs can reach

A PR from within the wrangle repo (maintainers, trusted contributors with write access, or Claude Code running under a maintainer's account) does get the secret and does trigger the companion repo. That dispatch runs wrangle's workflows at the PR's head SHA — which means it runs code the PR author wrote.

This is acceptable because:

1. **The PR author already has write access to wrangle.** They could already exfiltrate wrangle's own secrets directly. The companion repo's secrets are not an escalation.
2. **The companion repo's secrets are minimal-scope by design.** See "Companion repo secrets" below.
3. **The blast radius is bounded to staging.** Nothing the companion repo can touch matters downstream.

### Companion repo secrets

The companion repo holds only the secrets required to exercise wrangle's workflows end-to-end:

| Secret | Scope | What happens if compromised |
|--------|-------|------------------------------|
| `GITHUB_TOKEN` (built-in) | The companion repo only. `contents: read`, `packages: write` on companion-repo-scoped images. | Attacker can clobber `ghcr.io/tomhennen/wrangle-test-staging:*` image tags. No downstream consumers. |
| `TEST_REPO_PAT` (wrangle side) | `actions:write` on `tomhennen/wrangle-test` **only**. | Attacker can trigger test workflows. Cannot push code, read secrets, or touch other repos. |

The companion repo explicitly **does not** hold:

- Wrangle release signing keys, Cosign credentials, or any key used by wrangle's actual releases.
- Tokens with access to `tomhennen/wrangle` or any other repository.
- GitHub App credentials, SSH keys, or any long-lived authentication material.

If a malicious internal PR got as far as the companion repo's secrets, the worst possible outcome is clobbered staging images. Wrangle's real release path remains untouched.

### Prohibited patterns

The following are **not permitted** in the integration-test dispatch workflow:

- **`pull_request_target` triggers.** This would run with secrets available to fork PRs, nullifying the fork-PR-no-secrets defense. Use `pull_request` only.
- **Checking out the PR's code in a `pull_request_target` workflow.** Even if the trigger exists for another reason, checking out `${{ github.event.pull_request.head.sha }}` and executing it is the "pwn request" pattern.
- **Using an organization-level PAT** where a repo-scoped PAT would suffice. Scope creep makes compromise worse.
- **Reusing the companion repo's secrets in any other workflow** on that repo. Each workflow gets exactly the secrets it needs.

Any change to the dispatch workflow that could plausibly affect the security model requires review by a maintainer who explicitly confirms the fork-PR defense still holds.

## Companion repo layout

```
tomhennen/wrangle-test/
├── .github/
│   └── workflows/
│       └── test-wrangle.yml          # single workflow, one job per build type
├── shell/
│   ├── script.sh
│   └── test.bats
├── container/
│   ├── Dockerfile
│   └── app.sh
├── scan/
│   └── (small source tree with real dependencies)
└── README.md                         # explains what this repo is, points back at wrangle
```

### `test-wrangle.yml`

Triggered by `workflow_dispatch` with a `wrangle_ref` input. The workflow has one job per wrangle build type, each job invoking the corresponding reusable workflow at the passed ref:

```yaml
on:
  workflow_dispatch:
    inputs:
      wrangle_ref:
        description: "wrangle ref to test (SHA, branch, or tag)"
        required: true
        type: string

jobs:
  test-shell:
    uses: TomHennen/wrangle/.github/workflows/build_shell.yml@${{ inputs.wrangle_ref }}
    with:
      scan-path: shell

  test-container:
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_container.yml@${{ inputs.wrangle_ref }}
    with:
      path: container
      imagename: ghcr.io/tomhennen/wrangle-test-staging
      registry: ghcr.io
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}

  test-scan:
    uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@${{ inputs.wrangle_ref }}
```

New build types (npm, python, go, etc.) are added as additional jobs alongside these.

### Fixture requirements

Each fixture subdirectory meets the minimum shape for its build type, matching the same requirements an adopter project would:

| Build type | Clean-path fixture |
|-----------|-------------------|
| `shell` | `.sh` file + `.bats` file, both clean |
| `container` | `Dockerfile` + minimal build context |
| `scan` | Small source tree with real (ideally clean) dependencies; the test passes iff osv/zizmor produce no blocking findings |
| Future: `npm` | `package.json` + one `.ts`/`.js` file |
| Future: `python` | `pyproject.toml` + one `.py` file |
| Future: `go` | `go.mod` + one `.go` file |

Failure-path fixtures (intentionally broken projects, known-vulnerable dependencies, shellcheck violations) are **not required** in the companion repo. Failure-path behavior is exercised by wrangle's unit tests (with mocks), not by integration testing. The companion repo is for happy-path contract validation.

## Dispatch flow

On every wrangle PR:

1. **GitHub fires `pull_request` event.** The wrangle dispatch workflow (`.github/workflows/integration-test.yml`) starts.
2. **Fork-PR guard.** The job's `if:` checks that the PR head repo matches the base repo (`github.event.pull_request.head.repo.full_name == github.repository`). Fork PRs skip straight past the dispatch job; the check appears as "skipped" on the PR, with a link to this spec for context.
3. **Trigger companion repo.** Internal PRs run `gh workflow run test-wrangle.yml --repo tomhennen/wrangle-test -f wrangle_ref="${{ github.event.pull_request.head.sha }}"`. This uses `TEST_REPO_PAT` (available only to internal PRs, per GitHub's fork-PR secret exclusion).
4. **Locate the dispatched run.** The PAT lets the wrangle workflow list the companion repo's recent runs. The step picks the most recent run of `test-wrangle.yml` (sleeping briefly first to let GitHub register it), asserting its `headSha` matches the dispatched SHA as a sanity check.
5. **Wait for completion.** `gh run watch --exit-status` blocks until the companion repo's run finishes, exiting with the run's status.
6. **Surface result on PR.** The wrangle workflow step exits with the companion repo's status. GitHub's check API shows the workflow as pass/fail on the PR.

Total latency: typically 3–8 minutes per PR, depending on how many build types the companion repo tests and how long each takes on shared runners.

## What this tests

Integration tests layer on top of dogfooding and per-action structural tests. The layers are complementary, not redundant:

| Layer | What it covers | Where it lives |
|-------|----------------|----------------|
| **Per-action structural bats tests** (`<action-dir>/test.bats`) | YAML shape, SARIF upload steps exist, required inputs present, step names unchanged | wrangle repo, runs on every PR in `test.yml` |
| **Dogfooding** | `check_source_change.yml` and `build_shell.yml` on wrangle's own source | wrangle's own CI (`check_source_change.yml` + `build_shell.yml` invoked on every PR) |
| **Integration testing** (this spec) | All reusable workflows, including those wrangle can't dogfood, on an adopter-shaped project | companion repo, triggered on every internal PR |

### Coverage by reusable workflow

| Reusable workflow | Dogfooded? | Integration tested? | Why |
|-------------------|------------|---------------------|-----|
| `check_source_change.yml` | Yes (on wrangle's own source) | Yes (on adopter-shaped source) | Both layers valuable: dogfooding catches "does the workflow work in its actual home;" integration catches "does the workflow work from outside wrangle." |
| `build_shell.yml` | Yes | Yes | Same reasoning. |
| `build_and_publish_container.yml` | **No** (wrangle is not a container project) | Yes | Integration testing is the **only** coverage path for the container builder. Without it, the container builder is only structurally tested. |
| Future: npm, python, go | No (wrangle is none of these) | Yes | Same as container — integration testing is the only option. |

For the container builder and future build types, integration testing is not a layer on top of dogfooding; it is the whole end-to-end story.

## Failure contract

An integration test fails (and blocks the wrangle PR check) under these conditions:

- The companion repo's `test-wrangle.yml` run fails for any reason: a job fails, a setup step fails, the workflow times out, or the workflow cannot even be dispatched (companion repo's workflow file is malformed, etc.).
- The dispatch step in wrangle's workflow cannot locate the dispatched run (timeout on `gh run list`, API error).
- `gh run watch` times out (upper bound on how long the companion repo is allowed to run).

An integration test is **not** expected to fail under these conditions (if it does, the test has a real problem):

- Transient GitHub Actions runner issues — the dispatch step retries on known-transient failures and escalates only on persistent ones.
- Upstream action availability — actions pinned to SHAs do not shift, so upstream regressions do not flicker tests.
- Sigstore/Fulcio downtime for the container builder — handled by wrangle's own Cosign retry logic, which is part of the action under test.

Deterministic pass/fail is a requirement. Flaky integration tests erode the signal; any test that is "usually" green must be fixed or removed from the companion repo.

### Fork PR behavior

Fork PRs skip the dispatch job entirely. The check appears as "skipped" (not "failed") on the PR, with a clear explanation. Maintainers reviewing a fork PR can — after reading the code — merge it to a branch in the wrangle repo to get the integration test to run against it, or manually dispatch the companion repo workflow themselves with the fork's ref if they've vetted the code.

## Out of scope

- **Pre-merge feedback for fork PRs.** Fork PRs get wrangle's internal CI (bats, shellcheck, actionlint, dogfooding) and no integration test until a maintainer explicitly promotes the ref. There is no label-based gate or "approve for testing" mechanism in this spec — the added complexity is not worth the marginal pre-merge coverage when fork PRs are rare.
- **Multi-platform runners.** The companion repo tests against `ubuntu-latest` only. macOS and Windows integration testing is a future extension.
- **Multi-version testing.** The companion repo tests against wrangle at the PR's head SHA, not against older released versions of wrangle. Release-time regression testing against older adopter ref pins is a separate concern.
- **Load testing or performance benchmarking.** Integration testing validates contract correctness, not throughput.
- **Adopter onboarding testing.** Whether a brand-new adopter can successfully wire wrangle into their repo from `AGENTS.md` is a separate concern (covered by the adoption tests referenced in wrangle's main SPEC).

## Known limitations

- **Latency.** Integration tests add 3–8 minutes to a PR's check cycle, versus seconds for bats. Development workflows must tolerate that cost; quick iteration on non-action code still uses `./test.sh` locally.
- **Runner cost.** Every internal PR runs the full integration suite on shared runners. For high-PR-volume periods this could be a GitHub Actions budget concern; partial dispatch (only run the integration job for the affected build type based on the PR's diff) is a future optimization.
- **Companion repo drift.** The companion repo's fixtures can silently drift out of sync with wrangle's expectations (e.g., wrangle adds a required input and the companion repo isn't updated). Mitigation: a `dependabot`-like process or a recurring check that validates the companion repo against wrangle's current state.
- **PAT rotation.** `TEST_REPO_PAT` is a long-lived credential. It must be rotated periodically; the rotation process is out of scope for this spec but should be documented in wrangle's operational runbook when that exists.
- **Cross-repo observability.** A failing integration test on a wrangle PR points at a workflow run in the companion repo. Contributors need to follow that link to see what broke. This is an ergonomics cost of the companion-repo model compared to same-repo CI.

## Relationship to other wrangle testing

Integration testing sits alongside the testing layers already specified in wrangle's main `docs/SPEC.md` and `CLAUDE.md`:

- `actionlint`, `shellcheck`, `bats` — syntactic and unit-level checks. Fast, run on every PR, catch most regressions.
- Per-action structural tests (`<action-dir>/test.bats`) — action-shape invariants that actionlint and zizmor don't cover.
- Dogfooding — real-GHA end-to-end testing of the workflows wrangle itself uses.
- **Integration testing (this spec)** — real-GHA end-to-end testing of the workflows wrangle ships, on an adopter-shaped project, including the ones wrangle can't dogfood.
- Adoption testing (future) — whether a fresh repo can successfully adopt wrangle by following `AGENTS.md`. Not covered here.

Each layer catches regressions the others miss. None is a substitute for the others.
