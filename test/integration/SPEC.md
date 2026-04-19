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

The dispatch mechanism described below relies on a GitHub Actions property: `pull_request` workflows triggered from forks run without access to the base repo's secrets. The integration-test dispatch requires a secret (`TEST_REPO_PAT`, used to push a branch and open a PR in the companion repo). Fork PRs do not get that secret, so the dispatch silently fails for them — the companion repo is never touched by untrusted code.

Everything else about this design flows from that one property. If a future change would weaken it (for example, switching to `pull_request_target` to "get secrets on fork PRs"), the change would have to re-prove the security model from scratch. Changes that do that are prohibited unless they pass a dedicated security review.

### Fixtures are minimal and adopter-shaped

Each build type's fixture in the companion repo is the smallest possible project of that type: a single `.sh` file and one `.bats` test for the shell build type, a minimal `Dockerfile` plus a one-file context for the container builder, etc. Fixtures are sized to exercise the adopter contract, not the tool's internals — the tests are already covered elsewhere.

Fixtures are **real projects**, not mocks. The container fixture builds a real image and pushes it to a real staging location. The scan fixture has real dependencies that real OSV scans can run against. The point of integration testing is to catch things emulation can't; using mocks would reintroduce the emulator's limitations.

## Architecture

Three components, living in two repositories:

| Component | Location | Responsibility |
|-----------|----------|----------------|
| **Dispatch workflow** | `wrangle/.github/workflows/integration-test.yml` | Triggered on every wrangle PR. For PRs from within the wrangle repo, pushes an **ephemeral branch** to the companion repo with a generated workflow file that pins wrangle at the PR's head SHA, then opens a PR from that branch in the companion repo. Waits for the resulting check runs and surfaces combined pass/fail status on the wrangle PR. Cleans up the ephemeral branch and PR after. |
| **Companion repo** | `tomhennen/wrangle-test` (separate repository) | Small monorepo with one subdirectory per build type (`shell/`, `container/`, `scan/`). Ephemeral integration branches carry a generated `test-wrangle.yml` with one job per build type, each invoking the corresponding wrangle reusable workflow at the pinned SHA via `uses: TomHennen/wrangle/.github/workflows/<name>.yml@<literal-sha>`. |
| **Status wait logic** | Inside the dispatch workflow | Polls GitHub's check-runs API for the companion repo's PR. Succeeds iff all companion-side check runs conclude successfully. |

The companion repo is a single repo with subdirectories, not one repo per build type. Splitting would multiply infrastructure (per-repo secrets, per-repo CI history, per-repo PAT scoping) without any corresponding benefit — each wrangle build type operates on its own subdirectory via `path`/`scan-path`/etc. inputs, so they coexist cleanly.

### Why the ephemeral-branch-plus-PR mechanism

GitHub Actions does not permit expressions in the `@ref` portion of `uses:`. The ref must be a literal string resolved at workflow-parse time — `uses: owner/repo/.github/workflows/foo.yml@${{ inputs.sha }}` is rejected with an "Unrecognized named-value" error before the workflow runs. That rules out a single static companion workflow file that takes the wrangle ref as an input.

The workaround is to generate a fresh workflow file per wrangle PR, with the literal SHA baked in, on an ephemeral branch in the companion repo. The workflow file differs per branch; each wrangle PR gets its own independent branch and PR in the companion repo, so concurrent wrangle PRs do not contend with each other.

### Why both `push` and `pull_request` triggers

The generated companion workflow declares both `on: push` (for the branch push that creates the ephemeral branch) and `on: pull_request` (for the PR opening). This produces two workflow runs per wrangle PR, executing the same jobs in two different event contexts:

- **`push`-triggered run**: `github.event_name == 'push'`, so event-name-gated logic on the non-`pull_` branch executes. In particular, `build_and_publish_container.yml`'s SLSA provenance job (gated `if: ${{ ! startsWith(github.event_name, 'pull_') }}`) runs and the keyless signing + SLSA L3 path is exercised.
- **`pull_request`-triggered run**: `github.event_name == 'pull_request'`, so event-name-gated logic on the `pull_request` branch executes — the provenance skip is verified, and adopter-shaped pre-merge behavior (which is the most common real adopter trigger) is covered.

Running both closes the trigger-context asymmetry that a single-trigger design would leave open. Either run failing fails the wrangle PR check.

## Security model

### Threat: drive-by attack via fork PR

An attacker opens a PR from a fork of wrangle containing malicious code — for example, a modified composite action that exfiltrates secrets. If the integration-test workflow ran this code with secrets attached, the attacker would compromise those secrets.

### Defense: GitHub's baseline fork-PR secret exclusion

GitHub Actions has a built-in rule: `pull_request` workflows triggered from forks run **without** access to repository secrets. The integration-test workflow needs a secret (`TEST_REPO_PAT`, to push to and open PRs on the companion repo). Fork PRs do not get that secret, so:

- The `TEST_REPO_PAT` environment variable is unset in the dispatch step.
- Any `git push` or `gh pr create` against the companion repo fails with an authentication error.
- The integration-test check is skipped entirely via an explicit `if:` guard on `github.event.pull_request.head.repo.full_name == github.repository`, with a clear step summary message pointing at this spec.

Either way: **no malicious code from the fork reaches the companion repo**, because the companion repo is never touched.

### What internal PRs can reach

A PR from within the wrangle repo (maintainers, trusted contributors with write access, or Claude Code running under a maintainer's account) does get the secret and does trigger the companion repo. That dispatch pushes a branch and opens a PR in the companion repo, whose workflows then run wrangle's reusable workflows at the PR's head SHA — which means it ultimately executes code the PR author wrote.

This is acceptable because:

1. **The PR author already has write access to wrangle.** Under wrangle's current setup, any PR author with write access can already reach anything this workflow can reach — the companion repo's secrets are not an escalation. (If wrangle later adopts GitHub Environments to gate release secrets to a subset of maintainers, this reasoning tightens but does not break: the companion repo still holds only minimal-scope secrets.)
2. **The companion repo's secrets are minimal-scope by design.** See "Companion repo secrets" below.
3. **The blast radius is bounded to staging.** Nothing the companion repo can touch matters downstream.

### Trust asymmetry between wrangle and the companion repo

The security model treats the two repos asymmetrically:

- **Wrangle is trusted.** Compromising wrangle propagates to every adopter; protecting it is the whole point of this project. Secrets that matter (release signing keys, Cosign credentials, cross-repo tokens) live on the wrangle side and are not reachable by the integration-test mechanism.
- **The companion repo is not trusted — and does not need to be.** It is explicitly disposable: image tags under `ghcr.io/tomhennen/wrangle-test-staging` are rotated or deleted at any time; the repo itself is not a stable API; no external consumer may depend on it. Worst-case compromise of the companion repo is "someone clobbered staging," which the spec accepts by design.

This asymmetry is why `TEST_REPO_PAT` is scoped with `contents:write` + `pull-requests:write` on the companion repo. Those capabilities are what the dispatch mechanism needs (push an ephemeral branch, open a PR). A PAT with that scope, if leaked, lets an attacker push arbitrary workflow YAML to the companion repo and open PRs that run under the companion's `GITHUB_TOKEN`. But the companion's `GITHUB_TOKEN` has no access to wrangle, no access to release infrastructure, and can only reach the staging image path. The attacker's blast radius is bounded to the set of things the spec already says are acceptable losses. Minimizing the PAT scope beyond this — for example, to require fewer privileges on the companion — would cost real mechanism capability without buying any real security, because the things we are protecting are not reachable through this credential either way.

### Companion repo secrets

"Staging" throughout this spec refers to the image path `ghcr.io/tomhennen/wrangle-test-staging` and the companion repo itself. Both are disposable test surfaces: image tags are rotated, rebuilt, or deleted at any time; the companion repo is not a stable API; nothing downstream may depend on either. The companion repo's `README.md` must lead with a "Do not depend on this repo" banner making this explicit.

The companion repo holds only the secrets required to exercise wrangle's workflows end-to-end:

| Secret | Scope | What happens if compromised |
|--------|-------|------------------------------|
| `GITHUB_TOKEN` (built-in) | The companion repo only. `contents: read`, `packages: write` on companion-repo-scoped images. | Attacker can clobber `ghcr.io/tomhennen/wrangle-test-staging:*` image tags. No downstream consumers. |
| `TEST_REPO_PAT` (wrangle side) | `contents:write` + `pull-requests:write` on `tomhennen/wrangle-test` **only**. | Attacker can push branches and open/close PRs in the companion repo, which can trigger its workflows with arbitrary YAML. Workflows run under the companion's own `GITHUB_TOKEN`, which itself holds no cross-repo access. Net: attacker can clobber staging images and make noise in the companion repo's PR list. Cannot reach wrangle, read wrangle's secrets, touch other repos, or escape the staging blast radius. |

The companion repo explicitly **does not** hold:

- Wrangle release signing keys, Cosign credentials, or any key used by wrangle's actual releases.
- Tokens with access to `tomhennen/wrangle` or any other repository.
- GitHub App credentials, SSH keys, or any long-lived authentication material.

If a malicious internal PR got as far as the companion repo's secrets, the worst possible outcome is clobbered staging images. Wrangle's real release path remains untouched.

### Required permissions per build type

The secrets table above describes the **compromise impact** of `GITHUB_TOKEN` (what an attacker can do if they steal it). Separately, the companion repo's generated workflow must **grant** each reusable workflow the permissions it actually needs to run. Each build type's reusable workflow documents its required permissions; the companion repo must grant at minimum what each called workflow declares.

For the container builder specifically, `build_and_publish_container.yml` contains a `provenance` job gated `if: ${{ ! startsWith(github.event_name, 'pull_') }}`. On the `push`-triggered run the guard is truthy and the SLSA generator executes; on the `pull_request`-triggered run it is false and the job is skipped. Because both runs share the same workflow file, the `test-container` job must declare permissions sufficient for the `push` run — i.e., the superset, not the lowest common denominator:

- `contents: read`
- `packages: write`
- `id-token: write` (for OIDC / Cosign keyless signing, `push` run only)
- `actions: read` (for the SLSA generator, `push` run only)

Declaring these on the `pull_request` run is harmless — the permissions simply go unused when the provenance job is skipped. The shell and scan reusable workflows have smaller permission sets; consult each workflow's own declaration.

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
│       ├── test-wrangle.template.yml  # template copied + SHA-substituted onto integration/* branches
│       └── cleanup-integration.yml    # janitor: close stale integration PRs + delete stale branches
├── shell/
│   ├── script.sh
│   └── test.bats
├── container/
│   ├── Dockerfile
│   └── app.sh
├── scan/
│   └── (small source tree with real dependencies)
└── README.md                          # explains what this repo is, points back at wrangle
```

The `main` branch of the companion repo intentionally does **not** carry an active `test-wrangle.yml` — GitHub Actions does not permit expressions in `uses: @ref`, so the file must be generated fresh per wrangle PR with a literal SHA baked in. The template file lives at `.github/workflows/test-wrangle.template.yml` and is copied onto each ephemeral `integration/*` branch by the wrangle-side dispatch script after a single substitution of a `<WRANGLE_SHA>` placeholder. The template has a `.template.yml` suffix so GitHub Actions does not try to execute it from `main`.

The `README.md` **must** lead with a "Do not depend on this repo" banner — a short, visually prominent notice at the top of the file stating that the repo is a disposable test surface, that image tags under `ghcr.io/tomhennen/wrangle-test-staging` are rotated or deleted without notice, and that no external consumer may depend on either. This is a contract item, not a nicety: it is the human-visible counterpart of the "blast radius is bounded to staging" argument in the security model.

### `test-wrangle.template.yml`

The template defines both `push` and `pull_request` triggers so each wrangle PR produces two companion runs (see §"Why both `push` and `pull_request` triggers"). Each job pins wrangle via a `<WRANGLE_SHA>` placeholder that the dispatch script substitutes with the PR's head SHA before pushing to the ephemeral branch:

```yaml
on:
  push:
    branches: ["integration/**"]
  pull_request:
    branches: [main]

jobs:
  test-shell:
    uses: TomHennen/wrangle/.github/workflows/build_shell.yml@<WRANGLE_SHA>
    with:
      scan-path: shell

  test-container:
    permissions:
      contents: read
      packages: write
      id-token: write
      actions: read
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_container.yml@<WRANGLE_SHA>
    with:
      path: container
      imagename: ghcr.io/tomhennen/wrangle-test-staging
      registry: ghcr.io
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}

  test-scan:
    uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@<WRANGLE_SHA>
```

New build types (npm, python, go, etc.) are added as additional jobs alongside these. The `<WRANGLE_SHA>` token is substituted via a single `sed` in the dispatch script — the implementation PR should assert the token remains in the template so a refactor doesn't silently break substitution.

### `cleanup-integration.yml`

A janitor workflow on the companion repo, triggered on `schedule:` (e.g., hourly) and on `workflow_dispatch`, that closes any `integration/*` PRs whose wrangle PR is already closed and deletes `integration/*` branches older than a configurable age (default: 24 hours) that have no open PR. This prevents stale state from accumulating when a wrangle run is canceled mid-flight or the cleanup step in the dispatch script fails.

### Fixture requirements

Each fixture subdirectory meets the minimum shape for its build type, matching the same requirements an adopter project would:

| Build type | Clean-path fixture |
|-----------|-------------------|
| `shell` | `.sh` file + `.bats` file, both clean |
| `container` | `Dockerfile` + minimal build context |
| `scan` | Small source tree with dependencies pinned to versions that are clean (no osv/zizmor blocking findings) as of the companion repo's last maintenance pass; the test passes iff osv/zizmor produce no blocking findings |
| Future: `npm` | `package.json` + one `.ts`/`.js` file |
| Future: `python` | `pyproject.toml` + one `.py` file |
| Future: `go` | `go.mod` + one `.go` file |

Failure-path fixtures (intentionally broken projects, known-vulnerable dependencies, shellcheck violations) are **not required** in the companion repo. Failure-path behavior is exercised by wrangle's unit tests (with mocks), not by integration testing. The companion repo is for happy-path contract validation.

The scan fixture's "clean" invariant is maintained by pinning and periodic refresh, not by tracking a live vulnerability surface. Pinned versions mean the fixture's pass/fail state doesn't flicker when a new CVE drops against an otherwise stable dependency. The companion repo refreshes those pins on the same 7-day cadence wrangle uses for its own tool upgrades (see `CLAUDE.md` "Supply Chain Discipline"), at which point any newly-blocking finding is addressed before the pin is bumped. This trades slightly staler dependency data for deterministic CI — the right trade for a contract-validation harness, since real vulnerability surface on adopter projects is already covered by wrangle's per-tool unit tests.

## Dispatch flow

On every wrangle PR:

1. **GitHub fires `pull_request` event.** The wrangle dispatch workflow (`.github/workflows/integration-test.yml`) starts.
2. **Fork-PR guard.** The job's `if:` checks that the PR head repo matches the base repo (`github.event.pull_request.head.repo.full_name == github.repository`). Fork PRs skip straight past the dispatch job; the check appears as "skipped" on the PR, with a link to this spec for context.
3. **Generate the companion workflow file.** For internal PRs, the dispatch script clones the companion repo (via `TEST_REPO_PAT`), reads `.github/workflows/test-wrangle.template.yml` from `main`, substitutes the `<WRANGLE_SHA>` token with the wrangle PR's head SHA, and writes the result to `.github/workflows/test-wrangle.yml` on a fresh branch named `integration/pr-<wrangle-pr-number>-<short-sha>`.
4. **Push the ephemeral branch.** The script pushes the branch to the companion repo. This fires a `push` event against the branch — the generated workflow runs in `push` context, exercising event-name-gated logic on the non-`pull_` branch (in particular, the container builder's SLSA provenance job).
5. **Open a PR in the companion repo.** The script runs `gh pr create` against the companion repo, opening a PR from the ephemeral branch to `main`. This fires a `pull_request` event — the workflow runs a second time in `pull_request` context, exercising event-name-gated logic on the `pull_request` branch.
6. **Wait for completion.** The script polls `gh api /repos/tomhennen/wrangle-test/commits/<head-sha>/check-runs` (or equivalent) until all integration-related check runs have concluded. Both the `push`-triggered and `pull_request`-triggered runs report check runs against the same head SHA, so a single poll loop covers both.
7. **Surface result on the wrangle PR.** The dispatch script exits with success iff every polled check run concluded `success`. GitHub's check API then shows the wrangle workflow as pass/fail on the wrangle PR.
8. **Cleanup (runs in `if: always()`).** On completion, success or failure, the script closes the companion-repo PR and deletes the ephemeral branch. Any leaked state is reaped later by `cleanup-integration.yml` (see §"Companion repo layout").

Each wrangle PR gets its own ephemeral branch and its own companion-repo PR, so concurrent wrangle PRs do not contend. No global concurrency group is required on the wrangle side; a per-PR concurrency group (`integration-${{ github.event.pull_request.number }}`) prevents the same wrangle PR's duplicate runs (from force-push, etc.) from stepping on each other.

Total latency: typically 5–10 minutes per wrangle PR, dominated by the slower of the two companion runs. The `push` and `pull_request` runs execute in parallel on separate runners.

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

### Coverage guarantees and gaps

Integration testing makes specific guarantees — and specifically does **not** make several others. These gaps are known and accepted; they are documented here so future readers do not mistake silence for coverage.

**What integration testing covers:**

- Both the `push` and `pull_request` event contexts for every build type, by virtue of the dual-trigger companion workflow. Event-name-gated logic on either branch of a conditional is exercised.
- The reusable workflow surface wrangle ships (`.github/workflows/<name>.yml` invoked via `uses:`) against an adopter-shaped project. Input types, secret forwarding, `workflow_call` semantics, per-job permissions.
- The end-to-end build → sign → attest → upload path for the container builder, on `push`. The provenance-skip behavior on `pull_request`.

**What integration testing does not cover:**

1. **Composite-action-only consumers.** This spec tests the reusable workflow path. Adopters who call composite actions directly (e.g., `uses: TomHennen/wrangle/actions/scan`) get only the per-action structural bats coverage — the end-to-end wiring of composite-only consumers is not validated here.
2. **OIDC claim shape is companion-repo-specific.** Keyless Cosign signatures produced by the companion repo carry OIDC claims rooted at `tomhennen/wrangle-test`. Any future logic that validates claim subject, audience, or repo is only proven to work for that one claim shape, not for arbitrary adopters.
3. **Private-repo adopter paths.** The companion repo is public. GHCR auth, OIDC token issuance, and `private-repository: true` behaviors can differ in private repos; integration testing does not exercise those differences.
4. **Third-party trigger contexts.** The two triggers the companion exercises are `push` and `pull_request`. Adopters using `schedule:`, `workflow_dispatch`, `release:`, or `issue_comment:` triggers to invoke wrangle workflows are not covered; event-name conditionals on those specific events are not exercised here.

These are stated as guarantees the spec is **not** making, not as deficiencies to be fixed. The cost of closing each one (additional companion repos, additional signing identities, paid private-repo CI, matrix-trigger harnesses) exceeds the current value; if that calculus changes, this section is the right place to revisit.

### Guardrail for new event-name conditionals

Any new `github.event_name`-based conditional added to a reusable workflow, composite action, or downstream script requires an explicit integration-coverage decision in the PR that introduces it. Specifically: the PR description must state which event-name branches are exercised by the dual-trigger companion and which are not, and if any branch is not exercised, the PR must justify either accepting the gap or adding separate coverage (dogfooded fixture, structural bats assertion, etc.) before merge. This is a process-level guardrail — the test layers above cannot catch a newly-introduced but unexercised conditional branch; only a reviewer can.

## Failure contract

An integration test fails (and blocks the wrangle PR check) under these conditions:

- Any check run on the companion repo's ephemeral PR concludes as anything other than `success` — a job fails, a setup step fails, the workflow times out, or the workflow cannot parse at all.
- The dispatch step in wrangle's workflow cannot create the ephemeral branch, push it, or open the companion-repo PR (network failures, API errors, malformed template).
- The wait-loop polling `check-runs` times out before all integration-related check runs conclude (upper bound on how long the companion repo is allowed to run).

An integration test is **not** expected to fail under these conditions (if it does, the test has a real problem):

- Transient GitHub Actions runner issues — the dispatch step retries on known-transient API failures and escalates only on persistent ones.
- Upstream action availability — actions pinned to SHAs do not shift, so upstream regressions do not flicker tests.
- Sigstore/Fulcio downtime for the container builder — handled by wrangle's own Cosign retry logic, which is part of the action under test.

Deterministic pass/fail is a requirement. Flaky integration tests erode the signal; any test that is "usually" green must be fixed or removed from the companion repo.

### Fork PR behavior

Fork PRs skip the dispatch job entirely. The check appears as "skipped" (not "failed") on the PR, with a clear explanation. Maintainers reviewing a fork PR can — after reading the code — merge it to a branch in the wrangle repo to get the integration test to run against it, or manually generate and push the ephemeral companion branch themselves with the fork's SHA if they have vetted the code.

GitHub's "Require approval for outside collaborators" gate is deliberately **not** relied on here. That gate controls whether a fork PR's workflow runs at all, but it does not grant secret access after approval: `pull_request` workflows from forks run without secrets even when a maintainer approves — that's the hard GitHub invariant this entire security model depends on. So there is no safe "click to run integration test" button for fork PRs; obtaining pre-merge integration coverage would require `pull_request_target`, which this spec explicitly prohibits (see "Prohibited patterns").

## Out of scope

- **Pre-merge feedback for fork PRs.** Fork PRs get wrangle's internal CI (bats, shellcheck, actionlint, dogfooding) and no integration test until a maintainer explicitly promotes the ref. There is no label-based gate or "approve for testing" mechanism in this spec — the added complexity is not worth the marginal pre-merge coverage when fork PRs are rare.
- **Multi-platform runners.** The companion repo tests against `ubuntu-latest` only. macOS and Windows integration testing is a future extension.
- **Multi-version testing.** The companion repo tests against wrangle at the PR's head SHA, not against older released versions of wrangle. Release-time regression testing against older adopter ref pins is a separate concern.
- **Load testing or performance benchmarking.** Integration testing validates contract correctness, not throughput.
- **Adopter onboarding testing.** Whether a brand-new adopter can successfully wire wrangle into their repo from `AGENTS.md` is a separate concern (covered by the adoption tests referenced in wrangle's main SPEC).

## Known limitations

- **Latency.** Integration tests add 5–10 minutes to a PR's check cycle, versus seconds for bats. Development workflows must tolerate that cost; quick iteration on non-action code still uses `./test.sh` locally.
- **Runner cost.** Every internal PR runs the full integration suite (two companion runs × all build types) on shared runners. For high-PR-volume periods this could be a GitHub Actions budget concern; partial dispatch (only run the integration job for the affected build type based on the PR's diff) is a future optimization.
- **Companion repo drift.** The companion repo's fixtures and template can silently drift out of sync with wrangle's expectations (e.g., wrangle adds a required input and the companion repo isn't updated). Mitigation: a `dependabot`-like process or a recurring check that validates the companion repo against wrangle's current state.
- **PAT rotation.** `TEST_REPO_PAT` is a long-lived credential. It must be rotated periodically; the rotation process is out of scope for this spec but should be documented in wrangle's operational runbook when that exists.
- **Cross-repo observability.** A failing integration test on a wrangle PR points at check runs on a PR in the companion repo. Contributors need to follow that link to see what broke. This is an ergonomics cost of the companion-repo model compared to same-repo CI.
- **Ephemeral branch/PR accumulation.** Each wrangle PR creates one branch and one PR in the companion repo. The dispatch script cleans up on completion, but canceled wrangle runs, GitHub Actions-side crashes, or bugs in the cleanup step can leak state. The `cleanup-integration.yml` janitor (see §"Companion repo layout") closes stale PRs and deletes stale branches on a schedule; without it, the companion repo's PR list and branch list would grow unbounded.
- **Concurrency within a single wrangle PR.** A force-push to a wrangle PR triggers a new integration run while the previous one may still be in flight. A per-wrangle-PR concurrency group (`integration-${{ github.event.pull_request.number }}`) on the dispatch workflow, with `cancel-in-progress: true`, prevents duplicate runs from stepping on each other; the cleanup step on the canceled run tears down its ephemeral state.
- **API rate limits.** Each wrangle PR consumes several `TEST_REPO_PAT` API calls (clone, push, PR create, poll, PR close, branch delete). At current wrangle PR volume this is far below GitHub's 5000/hour PAT rate limit; at much higher volumes or during CI storms this could matter.

## Relationship to other wrangle testing

Integration testing sits alongside the testing layers already specified in wrangle's main `docs/SPEC.md` and `CLAUDE.md`:

- `actionlint`, `shellcheck`, `bats` — syntactic and unit-level checks. Fast, run on every PR, catch most regressions.
- Per-action structural tests (`<action-dir>/test.bats`) — action-shape invariants that actionlint and zizmor don't cover.
- Dogfooding — real-GHA end-to-end testing of the workflows wrangle itself uses.
- **Integration testing (this spec)** — real-GHA end-to-end testing of the workflows wrangle ships, on an adopter-shaped project, including the ones wrangle can't dogfood.
- Adoption testing (future) — whether a fresh repo can successfully adopt wrangle by following `AGENTS.md`. Not covered here.

Each layer catches regressions the others miss. None is a substitute for the others.
