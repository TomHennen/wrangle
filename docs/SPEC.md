# Wrangle v0.1 Specification

This document is the **map**: vision, lifecycle, architecture, design decisions,
and the security model. The precise **interface contracts** — each invariant
paired with the test or lint that enforces it — live in
[`docs/contracts/`](contracts/) and load on demand when you work on that
component. Rationale stays here; the rule lives in the contract.

## Vision

Project maintainers should ship features securely without tracking security tooling details. Security engineers should update tools and best practices without bothering maintainers.

Wrangle is a composable CI/CD framework for GitHub Actions that handles the full software development lifecycle — not just security scanning, but also building, testing, publishing, and provenance — using best practices out of the box.

### Core principles

1. **Full lifecycle** — wrangle handles source scanning, building, testing, publishing, SBOM generation, signing, and SLSA provenance. Not just one stage.
2. **One-shot adoption** — a maintainer picks a workflow template matching their project type, gets one or two workflow files, and everything works
3. **Pluggable tools** — new tools are added via adapters without changing adopting repos
4. **Automatic updates** — adopters reference wrangle's reusable workflows; updates flow to everyone
5. **AI-agent friendly** — designed so "Claude, adopt wrangle for this repo" just works

---

## Full Lifecycle

Wrangle covers the entire path from source to published artifact. Each stage has a corresponding reusable workflow that adopters can use independently or together.

### Stages

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Source     │    │   Build     │    │   Publish    │    │   Verify    │
│             │    │             │    │             │    │             │
│ • Vuln scan │───▶│ • Compile   │───▶│ • Push to   │───▶│ • SLSA      │
│ • Workflow  │    │ • Generate  │    │   registry  │    │   provenance│
│   linting   │    │   SBOM      │    │ • Sign with │    │ • Policy    │
│ • Scorecard │    │ • Scan SBOM │    │   Cosign    │    │   check     │
│ • Run tests │    │             │    │             │    │ • VSA       │
│ • SLSA      │    │             │    │             │    │             │
│   source    │    │             │    │             │    │             │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

| Stage | What wrangle does | Reusable workflow | Status |
|-------|------------------|-------------------|--------|
| **Source** | Vulnerability scanning (OSV), workflow linting (Zizmor), supply chain scoring (Scorecard), run tests, SLSA source provenance | `check_source_change.yml` | v0.1 |
| **Build** | Compile/build the project, generate SBOM, scan SBOM for vulnerabilities | `build_and_publish_*.yml` | v0.1 (container, python, npm, go) |
| **Publish** | Push artifact to registry, sign with Cosign | `build_and_publish_*.yml` | v0.1 (container, python, npm, go) |
| **Verify** | Generate SLSA L3 build provenance, verify attestations against policy (Ampel) | `build_and_publish_*.yml` / future | v0.1 (provenance), v0.2 (policy) |

### What adopters get today (container project example)

With two workflow files, a container project gets:

**Source workflow (`check_source_change.yml`):**
- Run project tests (detected automatically or configured) on every PR
- OSV vulnerability scanning on every PR and push
- Zizmor workflow security linting
- OSSF Scorecard supply chain assessment
- Results in GitHub Security tab via SARIF

**Build workflow (`build_and_publish_container.yml`):**
- Docker image built with Buildx (multi-platform capable, cached)
- SBOM generated automatically (SPDX format)
- SBOM scanned for vulnerabilities before publish
- Image pushed to container registry (ghcr.io)
- Image signed with Cosign (keyless, via Sigstore OIDC — the signature is tied to the GitHub Actions OIDC identity, so verifiers can confirm the image was built by a specific workflow in a specific repo, without managing signing keys)
- SLSA Level 3 provenance attestation via `slsa-github-generator`

This is the "batteries included" experience: the maintainer provides a Dockerfile and wrangle handles everything else.

### Build type extensibility

The `build/actions/` directory is the extensibility point for different project types:

| Build type | Directory | What it does | Status |
|-----------|-----------|-------------|--------|
| Shell | `build/actions/shell/` | Run shellcheck + tests (bats/shunit2), no publishable artifact | v0.1 (wrangle dogfoods this) |
| Container | `build/actions/container/` | Docker build, SBOM, sign, push | v0.1 (exists) |
| Python | `build/actions/python/` | Build wheel/sdist, generate SBOM, publish to PyPI | Future |
| npm | `build/actions/npm/` | Build, generate SBOM, publish to npm registry | Future |
| Go | `build/actions/go/` | Goreleaser-driven binary build, gofmt/vet/test/govulncheck, SBOM, publish to GitHub Releases (wrangle owns publish — no caller-bound OIDC constraint) | v0.2 |
| Generic | `build/actions/generic/` | Run user-defined build command, generate SBOM | Future |

Each build type follows the same pattern:
1. Build the artifact
2. Generate an SBOM describing it
3. Scan the SBOM for vulnerabilities
4. Publish the artifact
5. Sign the artifact
6. Generate SLSA provenance

New build types can be added without changing the source scanning workflow or the adopter's existing setup.

### Build action directory structure

Every build type lives in `build/actions/<type>/` and MUST contain these files. This is the same "everything for one capability lives in one directory" discipline wrangle applies to tools (`tools/<name>/`), extended to build actions:

| File | Purpose | Audience |
|------|---------|----------|
| `action.yml` | The composite action implementation | Runtime |
| `SPEC.md` | Detailed specification: inputs/outputs, step sequence, failure contract, trust model, limitations | Maintainers, reviewers, security auditors |
| `README.md` | User-facing how-to: quick start, copy-pasteable workflow example(s), required permissions, how to verify the output, links into `SPEC.md` for the details | Adopters (humans) and agents generating wrangle integrations |
| `test.bats` | Structural checks (YAML validity, pinned SHAs, required inputs, expected step names). Same pattern wrangle uses for tools (`tools/<name>/test.bats`). | CI |

Action-level behavioral testing — exercising the reusable workflow end-to-end against a real fixture project on real GitHub Actions infrastructure — happens in a dedicated integration-testing companion repo rather than inside this repo. The architecture, security model, and dispatch mechanism are specified in [`test/integration/SPEC.md`](../test/integration/SPEC.md). The short version: a companion repo runs each wrangle reusable workflow against a fixture, dispatched per-PR for internal contributors; fork PRs are excluded by GitHub's default fork-PR secret model.

The reusable workflow that wraps a build action (e.g., `.github/workflows/build_and_publish_container.yml`) is part of the same unit even though it lives outside the directory due to GitHub Actions' reusable-workflow location rules. The directory's `README.md` MUST document both the composite action and the reusable workflow entry points and make clear which one adopters should call.

**Why both SPEC.md *and* README.md?** They serve different audiences and should not be collapsed:

- `SPEC.md` is the contract. It's forward-looking, describes guarantees and failure modes, and exists so maintainers and reviewers can reason about whether the action is correct and whether a change preserves its invariants. It may describe behavior that is still being implemented.
- `README.md` is the how-to. It only describes currently-implemented, stable usage, and is structured so that an adopter (human or agent) can copy a workflow example, wire it into their repo, and verify the output without reading the spec. Agent-generated integrations in particular depend on a canonical, machine-readable usage doc — the README is that doc.

If `SPEC.md` describes behavior that hasn't shipped yet, `README.md` MUST NOT present it as available. Keeping the two in sync during implementation is part of landing a feature, not a follow-up.

### Workflow-command-injection guard for build composites

Every build composite MUST wrap its ecosystem invocations (compile, install, test, lint — anything that runs caller-controlled code or echoes caller-controlled content to the step log) in `lib/stop_commands_guard.sh`. GitHub Actions interprets any line on a step's output stream beginning with `::` as a workflow command (`::add-mask::`, `::add-path::`, `::set-output::`); without the guard a malicious dependency lifecycle hook, test, build backend, or `Dockerfile RUN` can hijack the build job just by printing such a line. See `docs/SLSA_L3_AUDIT.md` Finding 3 for the threat model and `lib/stop_commands_guard.sh` for the two supported wrap shapes (`run` for inline `run:` blocks, `begin` / `end` for `uses:` build steps).

This requirement is enforced by `test/test_build_guard_coverage.bats`, which enumerates every `build/actions/*/action.yml` and fails if a composite has no reference to the guard. A new build type cannot be added without either wiring in the guard or adding the composite to the explicit allowlist in that test (which requires a written rationale — today the list is empty).

The guarded window MUST also cover any post-script logic in the composite's `run:` block that echoes content derived from the build's output (a glob of build artifacts, an error message including filenames, etc.). The pattern is to push that logic INTO the guarded script (writing results to `$GITHUB_OUTPUT`, a file-based channel that stop-commands does not affect) rather than running it in the composite's `run:` block after the guard returns. An unguarded post-script `printf '%s\n' "${tarballs[@]}"` over attacker-influenced filenames is a workflow-command injection path that the guard around the build itself does NOT close.

**Adopter-visible side effect.** GitHub workflow commands intentionally emitted by wrapped build tools — e.g., `printf '::warning::version mismatch\n'` from an npm script, an `::error::` line from a pytest test, an `::notice::` from a `Dockerfile RUN` — are suppressed under the guard: they appear in the step log as plain text rather than surfacing as PR-level annotations. The trade is deliberate (an attacker cannot use a malicious dependency to call `::add-mask::` / `::add-path::` / `::set-output::`); adopters who want PR-level annotations from their build should emit them from a wrangle-controlled step (e.g., the source-scan workflow's SARIF upload) rather than from within their build script.

### Unified metadata layout

The on-disk `metadata/<type>/<shortname>/` layout that adopters and downstream
tooling depend on is specified in
**[contracts/metadata.md](contracts/metadata.md)**, with each path/filename
invariant paired with the test that enforces it.

### Shared SBOM vulnerability scanning

Steps 2–3 (generate SBOM, scan for vulnerabilities) apply to every build type that produces an artifact. How the SBOM is *generated* varies by build type (BuildKit for containers, language-specific tooling for Python/npm/Go), but how it is *scanned* does not — all SBOMs are scanned the same way using `osv-scanner`.

SBOM scanning is shared infrastructure, not per-build-type logic. All build types use a common scanning implementation (e.g., `lib/scan_sbom.sh`) rather than reimplementing scanning in each build action. This ensures consistent behavior: same tool, same SARIF output format, same non-blocking policy across all artifact types.

### Test integration

Wrangle doesn't replace your test framework — it orchestrates it. Tests run in **two places**:

1. **Source stage (on every PR):** The source workflow detects and runs the project's test command. This gives fast feedback on PRs before any build or publish step. Tests here use the shell/script build type adapter for detection.
2. **Build stage (on merge/tag):** Tests run again as part of the build, ensuring the artifact being published passes all checks.

Test detection by project type:
- **Shell projects:** `bats` tests, `make test`, or shellcheck
- **Container projects:** Tests run during `docker build` (multi-stage builds) or as a pre-build step
- **Future build types:** `pytest`, `npm test`, `go test`, etc.

If tests fail at either stage, the pipeline stops. No artifact is built or published from untested code.

### Build stage failure contract

The build stage has multiple failure points with different behaviors:

| Failure | Behavior | Rationale |
|---------|----------|-----------|
| **Tests fail** | Pipeline stops. No artifact built or published. | Broken code should never be released. |
| **Build fails** | Pipeline stops. | Nothing to publish. |
| **SBOM generation fails** | Pipeline stops. | Can't verify what's in the artifact without an SBOM. |
| **SBOM vulnerability scan finds issues** | Build continues. SARIF uploaded to Security tab. Findings visible but non-blocking. | Vulnerabilities in dependencies are informational — maintainers need to see them but shouldn't be blocked from shipping. Blocking on transitive dependency vulns creates alert fatigue and is often unactionable. |
| **Cosign signing fails** | Pipeline stops. Unsigned artifact is NOT published. | An unsigned artifact missing an expected security guarantee is indistinguishable from a supply chain attack. Publishing it trains users to accept unsigned artifacts, which is exactly the condition an attacker needs. |
| **SLSA provenance generation fails** | Pipeline stops. Artifact is NOT published without provenance. | Same reasoning — if adopters expect provenance and it's suddenly missing, that's either an attack or a broken release. Either way, don't ship it. "Oh sure, USUALLY this has provenance, but there was a problem" is the social engineering vector for supply chain attacks. |

This "fail on anything that weakens security guarantees" approach is stricter than the typical "warn on infra" pattern, but wrangle is a security tool — its releases must model the behavior it advocates. If Sigstore/Fulcio is down, the correct response is to wait and retry, not to ship without signing.

### Release-events gating

Every wrangle build-type reusable workflow MUST expose a `release-events` input that controls whether release-time side effects (SLSA provenance generation; in some build types, publish) run for a given event. The default is `non-pull-request`. Internally the workflow MUST delegate the decision to the shared composite action `actions/release_gate/`, which exposes a `should-release` output. The reusable workflow then:

1. Gates its own provenance job on `needs.gate.outputs.should-release == 'true'`.
2. Re-exports `should-release` as a workflow output so the caller's publish job (when one exists) can gate on the same value — keeping wrangle's internal gating and the caller's downstream gating in lockstep.

Supported `release-events` shorthands:

- `non-pull-request` (default) — every event except `pull_request*`.
- `tag-only` — push to `refs/tags/*` only.
- `main-and-tags` — push to `refs/heads/main` or `refs/tags/*`.
- A comma-separated list of `github.event_name` values (e.g., `push,workflow_dispatch`) for adopters who need exact control. The list matches purely on event name; ref filtering is only available through the shorthands above.

Why a shared composite. Centralizing the predicate means adopters get a single vocabulary across every build type, and refining the gate (adding a shorthand, supporting environments, applying ref filters to event lists) is a single-PR change rather than a sweep across every reusable workflow.

Why over-generation is acceptable for the default. SLSA L3 provenance is non-falsifiable: a verifier checks `--source-uri` and (where the consumer specifies it) `--source-tag` against the provenance's recorded `workflow_ref`. A `schedule`-cron run that nobody downstream consumes is harmless because no consumer references that `workflow_ref`. The cost of over-generation is generator-job runtime; the cost of under-generation is "the consumer expected provenance and didn't get it." Asymmetric — over-generate by default, let adopters tighten when they have a stronger threat model (e.g., `tag-only` to ensure unauthorized `workflow_dispatch` cannot mint provenance for a release that downstream verifiers might trust under a default policy).

Asymmetry: container vs. python. The container reusable workflow's docker push happens mid-composite inside `build/actions/container`; `release-events` currently gates the provenance and verify jobs in that workflow, not the push. The python reusable workflow has no publish step (PyPI Trusted Publishing's OIDC constraint means publish lives in the caller), so `release-events` gates provenance and verify, and `should-release` flows out to the caller's publish job. Build types MUST document this scope when their publish path differs from the python pattern.

### Release verification

Every wrangle build-type reusable workflow that produces an attestation MUST verify it before declaring success. Verification is default-on with a per-build-type opt-out input (`verify-provenance` for python, `verify-image` for container). The opt-out moves the integrity guarantee from "wrangle owns it" to "adopter owns it" — appropriate for adopters running custom verification flows.

Each build type's verify job:

1. Runs after the corresponding provenance/attestation job.
2. Is gated on `should-release == 'true' && inputs.verify-<build-specific> == true` so it only runs when there is something to verify.
3. Fails the workflow on verification failure. Standard `needs:` propagation then blocks any caller's release-time job (e.g., python publish, container release tagging).
4. Pins the cert identity to the exact tag of the upstream attestation generator. The bats tests assert this lockstep so a single-side bump fails CI loudly.

Why default-on. Verification belongs in wrangle as a default-on guarantee, not in adopter examples as a "recommended" step that they might forget. Without wrangle-owned verification, the "tampered between build and publish" attack window has no defender — the SLSA generator's provenance/attestation only covers what it built, not what the registry serves on subsequent reads. Owning verification is what makes wrangle's "build → release" contract end-to-end rather than per-step.

Why opt-out exists. Some adopters run custom verification policies (different `--source-uri` constraints, custom cert identities, ratchet-style multi-tag-tolerance). For those cases the opt-out lets them keep wrangle's build/provenance/attestation while replacing the verify step. The contract becomes: wrangle still pushes/builds/attests, but the integrity-between-build-and-publish guarantee shifts to the adopter.

### Consumer VSA verification

The signed VSA (`predicateType: https://slsa.dev/verification_summary/v1`) is the consumer trust boundary: a consumer trusts that one signed attestation instead of re-running the policy engine. For npm/go/python the supported check is **`cosign verify-blob-attestation` + a `jq` predicate-field check**: it binds the signer identity (wrangle's reusable workflow), the **origin repository** (`--certificate-github-workflow-repository`), and the artifact hash, with the `jq` decode covering the predicate fields. A one-command `ampel verify` against the wrangle-hosted `policies/wrangle-vsa-consumer-v1.hjson` PolicySet is **not recommended yet** — ampel (v1.2.1) matches only the cert's issuer + SAN, not the source-repository extension, so it cannot bind the origin repo ([#321](https://github.com/TomHennen/wrangle/issues/321)); it may return once that's fixed. Containers are a separate case: the VSA subject is an image digest with no file blob for `cosign verify-blob-attestation`, so the consumer uses `cosign verify-attestation` against the image. The container VSA is an OCI 1.1 referrer (not the `.att`-tag SLSA provenance), and `cosign verify-attestation` (cosign v3) reads it and binds the origin repository via `--certificate-github-workflow-repository`; the integration suite's `verify-container-vsa` job is the regression backstop. `slsa-verifier verify-vsa` is **not** usable: it requires `--public-key-path` and verifies only key-signed VSAs, while wrangle's are keyless (Fulcio/Sigstore). Per-build-type commands live in each `build/actions/<type>/README.md`.

The verifiable identity is the VSA's **signing certificate — wrangle's reusable workflow** (`build_and_publish_<type>.yml`), not `builder.id` (the SLSA generator) or `verifier.id` (`https://carabiner.dev/ampel@v1`, the engine, hard-coded). So consumers pin wrangle's workflow path as the cert identity and pass their own repo via `--certificate-github-workflow-repository` — the cosign path above; the one-command ampel path cannot bind the repo (it matches only issuer + SAN), per [#321](https://github.com/TomHennen/wrangle/issues/321).

**Build-vs-provenance-creation identity (a known gap).** For npm/go/python, *wrangle's* reusable workflow runs the real build (`npm pack`, `goreleaser`, `python -m build`) and the *generic* SLSA generator only creates and signs the provenance — so the provenance's `builder.id` names the prov-signer, and the provenance binds the *source repo* + *that a genuine generator signed it*, but **not which workflow in that repo built the artifact**. A different or compromised workflow in the same repo could feed its own hashes to the generic generator and get passing provenance. What closes this for npm/go is the VSA's signing identity (wrangle's reusable workflow). For **container** the generator isolates the build itself, so its `builder.id` is accurate. This is a documented gap, not a fix — see the README "Attestation trust gaps" section and [#316](https://github.com/TomHennen/wrangle/issues/316).

### Build Track level

Every wrangle build-type reusable workflow that produces provenance — `build_and_publish_npm.yml` (npm and pnpm), `build_and_publish_python.yml` (pip and uv), `build_and_publish_container.yml`, and `build_and_publish_go.yml` — meets **SLSA v1.2 Build L3**. `build_shell.yml` produces no artifact and no provenance, so no Build Track level applies to it.

Wrangle's user-facing docs claim exactly **one** Build Track level per workflow — Build L2 or Build L3 — and never a finer-grained, requirement-by-requirement breakdown. An adopter should not have to reason about individual SLSA L3 requirements ("Provenance is Unforgeable" versus "Isolated") to know what a workflow delivers; the single Build Track level is the claim. The full per-builder analysis behind the L3 verdicts is [`docs/SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md).

Two conditions narrow every Build L3 claim:

- **Reusable consumption only.** The verdict assumes the adopter consumes wrangle through one of wrangle's reusable workflows. Calling a `build/actions/<type>` composite directly from an adopter-authored job forfeits the build-vs-sign job separation and is **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the ephemeral-build-environment assumption the L3 verdicts depend on.

**Cache isolation is part of the L3 claim.** SLSA v1.2's "Isolated" requirement states the output of a build MUST be identical whether or not a cache is used. Three of wrangle's cache surfaces — the container path's BuildKit `type=gha` cache, the python-uv sub-path's uv cache, and the Go path's `actions/setup-go` module + build caches — are shared cross-build via GitHub's cache service and are not re-verified on cache hits in a way that defeats a cache-scope attacker, so a release build must not consume them. Each of those three workflows gates its build cache on the same `should-release` signal that gates provenance: release builds (`should-release == 'true'`) build cache-free; PR builds keep caching for fast iteration, since they produce no attested artifact. The npm sub-path keeps its cache in both contexts because `npm ci` re-verifies every cached tarball against the lockfile on install; the pnpm sub-path and the python-pip sub-path consume no cross-build cache at all. See [`docs/SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md) Findings 1 and 2 and its "Release-vs-PR build asymmetry" section.

## Architecture

### Layers

```
┌──────────────────────────────────────────────────┐
│  Adopting Repo                                   │
│  .github/workflows/check_source_change.yml       │
│  (calls wrangle's reusable workflow)             │
└──────────────────┬───────────────────────────────┘
                   │ uses:
┌──────────────────▼───────────────────────────────┐
│  Wrangle Reusable Workflow                       │
│  .github/workflows/check_source_change.yml       │
│  (orchestrates composite actions)                │
└──────────────────┬───────────────────────────────┘
                   │ uses:
┌──────────────────▼───────────────────────────────┐
│  Wrangle Composite Action                        │
│  actions/scan/action.yml                         │
│  (installs tools, runs adapters, uploads results)│
└──────────────────┬───────────────────────────────┘
                   │ calls
┌──────────────────▼───────────────────────────────┐
│  Orchestrator + Tools                            │
│  run.sh → tools/<name>/install.sh                │
│         → tools/<name>/adapter.sh                │
│  (download binaries, run tools, normalize output)│
└──────────────────────────────────────────────────┘
```

### Directory Layout

```
wrangle/
├── tools/                  # One directory per tool — everything in one place
│   ├── osv/
│   │   ├── install.sh      # Downloads + verifies OSV-Scanner binary
│   │   ├── adapter.sh      # Runs OSV-Scanner, produces SARIF
│   │   └── test.bats       # Tests for this tool
│   └── zizmor/
│       ├── install.sh
│       ├── adapter.sh
│       └── test.bats
├── lib/                    # Shared helpers
│   ├── download_verify.sh  # wrangle_download_verify(), wrangle_verify_provenance()
│   ├── format_sarif_summary.sh  # SARIF → markdown summary (with sarif_to_md.sh fallback)
│   ├── log_findings.sh     # Per-finding CI log lines (issue #158)
│   ├── sanitize.sh         # wrangle_sanitize_output() — shared HTML stripping + truncation
│   ├── sarif_to_md.sh      # SARIF → human-readable markdown (per-tool)
│   └── tool_banner.sh      # Print visual banner for tool log attribution
├── actions/                # GitHub Actions entry points
│   ├── scan/
│   │   └── action.yml      # Composite action: scan source code
│   └── scorecard/
│       └── action.yml      # OSSF Scorecard wrapper (GitHub Action, not adapter)
├── build/                  # Build/publish workflows
│   └── actions/
│       └── container/
│           └── action.yml  # Container build/publish action
├── run.sh                  # Orchestrator (installs + runs tools)
├── gh_workflow_examples/   # Copy-paste templates for adopters
├── test/                   # Integration tests, fixtures, schemas
├── docs/
│   └── SPEC.md             # This document
└── AGENTS.md               # AI agent adoption instructions
```

**Why per-tool directories?** Everything related to a single capability lives in one place. To understand "what does wrangle's OSV integration entail?" — look in `tools/osv/`. To add a new tool — copy any `tools/<name>/` directory and adapt. This makes the project easy to navigate and extend.

**Note on root layout:** `run.sh` and `AGENTS.md` live at the repo root for discoverability. If the repo grows and the root gets noisy, `run.sh` could move into a `src/` directory (updating the `../../` path constraint in the composite action accordingly).

**`build/actions/` extensibility:** The `build/actions/container/` directory is the first build type. Future build types (e.g., `build/actions/python/`, `build/actions/npm/`) follow the same pattern, providing opinionated build+publish workflows for different project types.

---

## Component & integration contracts

The precise interface contracts — every invariant paired with the test or lint
that enforces it — live in [`docs/contracts/`](contracts/). This section is a
map; load the relevant contract when working on that component.

| Contract | Covers |
|---|---|
| [Adapter Script Interface](contracts/adapter.md) | `tools/<name>/adapter.sh` — exit codes 0/1/2, SARIF output, stripped env |
| [Install Script Interface](contracts/install_script.md) | `tools/<name>/install.sh` — download, verify, atomic placement, idempotency |
| [Integrity Verification](contracts/verification.md) | the no-fallback verification-tier ladder every download passes |
| [Orchestrator Interface](contracts/orchestrator.md) | `run.sh` — tool-name validation, env isolation, timeouts, exit codes |
| [Composite Action Interface](contracts/composite_action.md) | adopters calling `actions/scan` |
| [Reusable Workflow Interface](contracts/reusable_workflow.md) | adopters calling the reusable workflows |

The two tool patterns (adapter vs. action) and the catalog of supported tools
follow below.

## Supported Tools (v0.1)

| Tool | Pattern | What it does |
|------|---------|-------------|
| [OSV-Scanner](https://github.com/google/osv-scanner) | Adapter | Scans dependencies against the OSV database |
| [Zizmor](https://github.com/zizmorcore/zizmor) | Action (wraps `zizmorcore/zizmor-action`) | Security-focused linting of GitHub Actions workflows |
| [OSSF Scorecard](https://scorecard.dev/) | Action (wraps `ossf/scorecard-action`) | Assesses repo security health across 18+ categories |
| [Dependency Review](https://github.com/actions/dependency-review-action) | Action (wraps `actions/dependency-review-action`) | PR-time gate: blocks PRs that introduce known-vulnerable dependencies. Runs on `pull_request` events only |

### Two Tool Patterns

Every tool lives in `tools/<name>/` regardless of which pattern it uses. There are two patterns:

**Adapter pattern** — for tools distributed as standalone binaries (e.g., OSV-Scanner). The orchestrator (`run.sh`) handles installation and execution:

```
tools/<name>/
├── install.sh    # Downloads + verifies the tool binary
├── adapter.sh    # Runs the tool, produces SARIF
└── test.bats     # Tests for both scripts
```

**Action pattern** — for tools that have an official GitHub Action or are best installed via their ecosystem's package manager (e.g., Zizmor, Scorecard). A thin composite action wraps the upstream action:

```
tools/<name>/
├── action.yml    # Composite action wrapping the upstream action
└── test.bats     # Structural tests + CI integration tests
```

**Tool-error marker contract (action pattern).** Action-pattern wrappers cannot rely on the upstream action's exit code alone: `continue-on-error: true` is typically required so wrangle's own collection step runs after the upstream exits non-zero on findings, which also swallows genuine tool errors. Without a separate signal an errored run produces an empty SARIF that `lib/check_results.sh` reads as "no findings" — silently fail-open (issue [#222](https://github.com/TomHennen/wrangle/issues/222)).

To close that gap, action-pattern wrappers SHOULD write a per-tool marker file at `$WRANGLE_METADATA_DIR/<tool>/error` (via `lib/write_tool_error_marker.sh`) whenever the upstream step fails in a way that does NOT correspond to "found issues" (e.g., API unavailable, dependency database disabled, malformed upstream output, image-pull failure mid-run). Contract:

1. The marker is a plain text file. Its first line is logged by `lib/check_results.sh` after passing through `wrangle_sanitize_output`, so wrappers do not need to pre-sanitize upstream output.
2. `lib/check_results.sh` treats the marker as **fail-closed** for `:fail` policy (non-zero exit) and **informational** for `:info` policy.
3. The marker takes precedence over the SARIF count. Wrappers MAY also write a synthesized empty SARIF as a fallback so downstream consumers (step summary, Code Scanning upload) always have a file; the marker prevents that fallback from being misread as zero findings.
4. `lib/format_sarif_summary.sh` surfaces a `Tool error` status in the step-summary table when the marker is present, and the per-tool Code Scanning upload in `actions/scan/action.yml` SHOULD be gated on the marker's absence to avoid overwriting prior valid runs with an empty SARIF.

The marker is the canonical signal — adapter-pattern tools already disambiguate via their exit code (0/1/2) per the Adapter Contract above, so they do not write a marker.

Use the action pattern when:
- The tool has a well-maintained official GitHub Action
- The tool's recommended installation method requires an ecosystem runtime (cargo, pip, etc.) that wrangle shouldn't depend on
- The tool requires the GitHub Actions context (repository metadata, API access) that the adapter pattern's environment isolation strips

Use the adapter pattern when:
- The tool publishes standalone release binaries as its primary distribution
- The tool can run without GitHub Actions context
- You want the strongest environment isolation (adapters run with stripped env vars)

### Supported Platforms (v0.1)

v0.1 targets **Linux x86_64** (Ubuntu) runners only. This is what GitHub-hosted `ubuntu-latest` provides and covers the vast majority of CI workloads.

The install scripts include OS/arch detection (`linux/darwin`, `amd64/arm64`) as forward-looking scaffolding, but macOS and ARM runners are not tested or guaranteed to work in v0.1. Platform support will expand based on demand.

### Adding a New Tool

**Adapter pattern** (standalone binary):

1. Create `tools/foo/` directory with:
   - `install.sh` — uses `lib/download_verify.sh` for download and verification
   - `adapter.sh` — follows the adapter contract above
   - `test.bats` — tests using mock binaries (fast, deterministic)
2. Add `foo` to the orchestrator's default tool list in `actions/scan/action.yml`

**Action pattern** (wraps upstream GitHub Action):

1. Create `tools/foo/` directory with:
   - `action.yml` — composite action that wraps the upstream action. Must pin the upstream action to a full commit SHA. Must write SARIF output to `$WRANGLE_METADATA_DIR/foo/output.sarif` (workspace-relative, set by the scan action via `$GITHUB_ENV`). Must also produce human-readable output as `output.md` (via `lib/sarif_to_md.sh` or a tool-specific formatter) or `output.txt` for the step summary details section. Must print a log attribution banner (via `lib/tool_banner.sh`) as the first step.
   - `test.bats` — structural tests (action.yml exists, SHA pinned, etc.)
2. Add a `uses: ./tools/foo` step in `actions/scan/action.yml`

Everything for one tool lives in one directory. No Docker images, no registry management, no workflow changes for adopters.

### Tool Sub-specifications

Each tool's detailed specification lives in `tools/<name>/SPEC.md` alongside the code it describes. Summary:

| Tool | Pattern | Default policy | Details |
|------|---------|---------------|---------|
| OSV-Scanner | Adapter | `:fail` | [`tools/osv/SPEC.md`](../tools/osv/SPEC.md) |
| Zizmor | Action | `:fail` | [`tools/zizmor/SPEC.md`](../tools/zizmor/SPEC.md) |
| OSSF Scorecard | Action | `:info` | [`tools/scorecard/SPEC.md`](../tools/scorecard/SPEC.md) |
| Dependency Review | Action | `:fail` | [`tools/dependency-review/SPEC.md`](../tools/dependency-review/SPEC.md) |

### Metadata Directory

The metadata directory (`$GITHUB_WORKSPACE/.wrangle/metadata/`) is workspace-relative. This is required because Scorecard's Docker container only mounts `$GITHUB_WORKSPACE`, not `$RUNNER_TEMP`. The directory is set via `$GITHUB_ENV` as `WRANGLE_METADATA_DIR` and is available to all steps in the job.

Structure after a scan:
```
.wrangle/metadata/
├── osv/
│   └── output.sarif
├── zizmor/
│   ├── output.sarif
│   ├── output.md
│   └── error           # optional: tool-error marker (action pattern only)
└── scorecard/
    ├── output.sarif
    └── output.md
```

The optional `error` file is the tool-error marker for action-pattern tools — see "Tool-error marker contract" under [Two Tool Patterns](#two-tool-patterns).

The `.wrangle/` directory is in `.gitignore` to prevent accidental commits. The orchestrator's filesystem check (`run.sh`) excludes the metadata directory from its pre/post snapshots.

**Future use:** The metadata directory is designed to become the source for signed attestations: "this commit was scanned by tools X, Y, Z with these results."

---

## Design Decisions

### Binary downloads over Docker images

**Previous approach:** Tools were wrapped in Docker images, pushed to ghcr.io, and run via `docker run` with volume mounts.

**New approach:** Tools are downloaded as standalone binaries and run directly.

**Rationale:**
- **Speed:** No image pull latency (cached binary downloads are near-instant)
- **Simplicity:** No container registry to manage, no image build pipeline
- **Portability:** Works on any runner (macOS, self-hosted, ARM — not just Linux with Docker)
- **Testability:** No Docker-in-Docker complexity; scripts testable with bats-core locally
- **Adoption friction:** No authentication needed to pull tool images

The container *build/publish* workflow (for building adopters' Docker images) remains unchanged.

### Reusable workflow + composite action (two layers)

The reusable workflow exists so adopters get a clean `uses:` interface with `workflow_call`. The composite action exists so the implementation can use `${{ github.action_path }}` for path resolution. GitHub requires this split because reusable workflows cannot use `github.action_path`.

### SARIF as the universal output format

All tools produce SARIF 2.1.0. This enables:
- Upload to GitHub Code Scanning (appears in Security tab)
- Consistent programmatic processing across tools
- A single summary formatter for all tools

Human-readable output (markdown/text) is optional and used only for step summaries.

### Per-tool SARIF uploads (not merged)

Each tool's SARIF file is uploaded to GitHub Code Scanning separately via `github/codeql-action/upload-sarif` with a per-tool `category` (e.g., `wrangle/osv`, `wrangle/zizmor`). This means:
- Each tool appears as a separate check run in the Security tab
- Findings are attributed to the specific tool that found them
- A noisy tool can be identified and tuned without affecting others

The alternative (merging all SARIF into one file) was rejected because it loses tool attribution and makes it harder to diagnose which tool produced which finding.

---

## Security Model

### Threat Model

Wrangle runs security tools on behalf of adopting repositories. This makes it a high-value target — a compromised wrangle could affect every adopter. The primary threats are:

1. **Compromised upstream tool release** — a malicious binary is published to a tool's GitHub releases page
2. **Compromised wrangle itself** — an attacker gains commit access to the wrangle repo
3. **Malicious adapter inputs** — attacker-controlled data flows into shell commands
4. **Tool misbehavior** — a tool writes outside its output directory, exfiltrates data, or produces malicious SARIF
5. **Adopter trigger misconfiguration** — an adopter wires wrangle's reusable workflows under a GitHub Actions trigger that runs attacker-influenced code in the base repo's privileged context. See "Trigger Model" below.

### Trigger Model

The trigger-safety contract — `actions/preflight_guard` MUST refuse
`pull_request_target` and `workflow_run` chains triggered by it, the
`_guard`/`_gate` naming convention, and the fail-closed wiring (guard is the
first job; every other job `needs:` it; guard runs with `permissions: {}`) — is
specified in **[contracts/triggers.md](contracts/triggers.md)**.

### Integrity Verification

The four-tier, no-fallback verification ladder (SLSA provenance / Sigstore
signature / hardcoded SHA-256 / `go install` via sum.golang.org) and its
load-bearing security invariants are specified in
**[contracts/verification.md](contracts/verification.md)**.

### Shared libraries

The download/verify helpers (`wrangle_download_verify`,
`wrangle_verify_provenance`, `wrangle_verify_signature`) and the shared output
helpers (`sarif_to_md.sh`, `tool_banner.sh`, `sanitize.sh`, `log_findings.sh`)
are defined in [`lib/`](../lib/) and documented at their definitions. Their
caller-facing invariants live in the relevant interface contracts under
[`docs/contracts/`](contracts/); this spec no longer restates their signatures
(the old embedded copies had drifted from `lib/`).

### Sandboxing and Isolation

**What's enforced:**
- Tool names are validated against `^[a-z][a-z0-9_-]*$`
- Sensitive environment variables are stripped before adapter execution
- All shell variable expansions are quoted to prevent injection
- Inputs are passed via environment variables, not `${{ }}` interpolation

**What's NOT enforced (known limitations):**
- Adapters run directly on the runner with no filesystem isolation. A malicious tool binary could read/write anywhere the runner user can. The previous Docker-based design provided container isolation; the binary-download approach trades this for speed and simplicity.
- No egress restrictions on tool network access. A compromised tool could exfiltrate source code.
- No runtime monitoring of tool behavior (process spawning, file access).

**Mitigations for known limitations:**
- Integrity verification (checksums + SLSA provenance) is the primary defense against malicious binaries
- GitHub-hosted runners are ephemeral, limiting the blast radius of any compromise
- For self-hosted runners, adopters should use [StepSecurity Harden-Runner](https://github.com/step-security/harden-runner) alongside wrangle for network monitoring
- Post-execution filesystem check: the orchestrator snapshots the workspace file list before and after each adapter run, flagging any unexpected file modifications outside `output_dir`
- Future versions may use lightweight sandboxing (bubblewrap, firejail) on Linux runners

### Protecting Wrangle Itself

Wrangle is a supply chain amplifier — a compromise of wrangle propagates to every adopter. Protections for the wrangle repo itself:

- **[SLSA Source Track](https://slsa.dev/spec/v1.2/):** Wrangle adopts the SLSA source track via [slsa-framework/source-tool](https://github.com/slsa-framework/source-tool) to enforce branch protection, generate source provenance attestations, and establish a verifiable chain of trust for its own source code. This protects against threat #2 (compromised wrangle).
- **Action reference pinning:** All third-party actions pinned to full commit SHAs (protects against upstream action compromise).
- **Signed commits:** All commits to the wrangle repo should be signed.
- **Minimal permissions:** Wrangle's own workflows request only the permissions they need.
- **Dependency management:** Dependabot for GitHub Actions dependencies; `make update-tool` for tool binary versions.
- **SLSA build provenance:** When wrangle produces releasable artifacts (e.g., if it ships a CLI or pre-built actions), those artifacts should have SLSA L3 build provenance via `slsa-github-generator`, the same standard wrangle helps adopters achieve. Aspirational — not currently in a numbered release milestone.
- **Delayed dependency updates:** Wrangle does not auto-merge dependency updates immediately. New versions of upstream tools are adopted only after a delay (e.g., 7 days) to allow the community to discover supply chain attacks before wrangle amplifies them to all adopters. This follows the [OpenSSF Concise Guide for Evaluating Open Source Software](https://best.openssf.org/Concise-Guide-for-Evaluating-Open-Source-Software) principle of not being the first to adopt a new release.

### Action Reference Pinning

All `uses:` references in wrangle's own workflows and examples MUST be pinned:

| Reference type | Pinning requirement |
|---------------|---------------------|
| Third-party actions | Full commit SHA |
| Wrangle's own actions (in examples) | Release tag (e.g., `@v0.1.0`) |
| Wrangle internal refs in reusable workflows | Relative path (`./`) — resolves to the workflow's own repo at the called ref |
| Wrangle internal refs in composite actions | Relative path (`./`) — resolves to the same repo at the called ref |

Adopters are advised to pin to a release tag. The `@main` ref MUST NOT appear in any `uses:` line in the repo, including examples and documentation.

### Output Sanitization

Tool output (SARIF, markdown, plain text) flows into `$GITHUB_STEP_SUMMARY` and GitHub Code Scanning. Before writing to the step summary:
- HTML tags are stripped
- Output is truncated to prevent summary flooding
- Markdown is limited to safe formatting (no raw HTML, no JavaScript links)
- `jq` exit codes are checked; malformed SARIF causes a tool failure (exit 2), not a silent pass

---

## Testing Strategy

### Local (fast, TDD-friendly)

```bash
make test    # Runs all local checks
```

Layers:
1. **actionlint** — validates all workflow and action YAML files
2. **shellcheck** — lints all shell scripts
3. **bats-core** — unit tests for adapters, install scripts, orchestrator, and formatter
4. **SARIF schema validation** — validates fixture/output SARIF against the 2.1.0 JSON schema
5. **zizmor** — workflow security linter run against `.github/workflows/`, `actions/`, `tools/`, `build/`. Findings fail `make test`; the only suppression surface is `.zizmor.yml`.

`./test.sh` (the canonical preflight) runs all of the above. Use `./test.sh quick` for an inner-loop iteration that skips zizmor when you're only touching shell or bats fixtures — but the full suite must pass before pushing. `./test.sh ci` is an explicit alias for the full suite.

**Adapter testing pattern:** Per-tool `test.bats` files (in `tools/<name>/`) test the adapter and install scripts in isolation using mock tool binaries that produce fixture SARIF. This keeps local tests fast and deterministic. The `test/` directory contains integration tests that exercise the orchestrator and composite action end-to-end, plus shared fixtures (sample SARIF files, SARIF JSON schema) and CI-specific tests that download real tools and run them against the wrangle repo itself (dogfooding).

### CI (integration)

`.github/workflows/test.yml` runs `make test` plus integration tests that exercise the composite action via `uses: ./actions/scan`.

### End-to-end (cross-repo)

[TomHennen/Concordance](https://github.com/TomHennen/Concordance) serves as the external test repo. A successful run there proves the full adoption path works.

---

## Adoption Path

### For humans

1. Copy the workflow from `gh_workflow_examples/check_source_change.yml` into your repo at `.github/workflows/check_source_change.yml`
2. Adjust the branch name if your default branch isn't `main`
3. Push. Done.

### For AI agents and new adopters

The README's quick-start section and the workflow examples in `gh_workflow_examples/` provide adoption instructions. Together they MUST cover:

1. A single-command adoption instruction (e.g., "create this file at this path")
2. The exact workflow YAML to use, parameterized by project type
3. The required GitHub permissions
4. How to detect project type (check for Dockerfile, language files, etc.)
5. Expected output after adoption (what the user should see on their next PR)

If the project type is unknown (no Dockerfile, no recognized language files), adopt only the source scanning workflow — this is always applicable regardless of project type.

`AGENTS.md` in the repo root may additionally provide AI-agent-specific instructions. It is not required; the README and examples are the primary adoption surface.

### Long-term: OpenSSF contribution

The adapter pattern and tool composition logic are candidates for contribution to OpenSSF (e.g., as part of Minder or a new working group). The spec and implementation will be designed with this handoff in mind.

---

## Roadmap

Release scope and forward-looking work are tracked in GitHub
[issues](https://github.com/TomHennen/wrangle/issues) and
[milestones](https://github.com/TomHennen/wrangle/milestones), which stay current
in a way a hand-maintained list in this file did not. (The previous embedded
roadmap had drifted — e.g. listing build types as "Future" that had already
shipped.)
