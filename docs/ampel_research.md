# Integrating Ampel into wrangle: Design Analysis and Implementation Plan

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Bootstrap:** keep `slsa-verifier` as wrangle's install-time trust anchor through the final step of the rollout. | AMPEL ships a sigstore-bundle SLSA provenance (`ampel-v1.2.1.provenance.json`) that `wrangle_verify_provenance` already knows how to verify. Adding a self-verify dance buys nothing. |
| 2 | **Policy distribution:** wrangle authors the `wrangle-default-v1` and `wrangle-strict-v1` PolicySets in `policies/` and references the upstream `carabiner-dev/policies` files by SHA-pinned VCS locator (`git+https://github.com/carabiner-dev/policies@<sha>#slsa/slsa-builder-id.json`). No vendored copies. Dependabot — or a manual `make bump-policies` shim if Dependabot can't reach the URI — bumps the SHA across all PolicySets atomically. | Mirrors how wrangle pins every other upstream dep (actions, tool binaries) by SHA rather than vendoring, matches the Fritoto demo's own reference pattern (`policies/fritoto-gate-publish.hjson` references upstream policies by VCS locator, not by vendored copy), and removes the Apache-2.0 `LICENSE`/`NOTICE` redistribution obligation that vendoring would carry. Trade-off: Ampel resolves the VCS locator on each verify, so the runner needs network access to `github.com` (already required for `actions/checkout`). |
| 3 | **VSA signing identity:** sigstore keyless via GitHub OIDC, using `carabiner-dev/actions/ampel/verify` as published — no custom signing wrapper. | The published action already signs results via `bnd statement`, matching `slsa-github-generator`'s identity model. Adopters verify with a stable workflow-path regex. |
| 4 | **VSA storage:** GitHub release asset is the canonical artifact, named per the in-toto v1 bundle convention (`<artifact>.intoto.jsonl`). Workflow-artifact and `gh attestation` store are redundant convenience copies. | Adopters can `wget` the release asset without GitHub auth; the `.intoto.jsonl` name matches the [in-toto attestation bundle spec](https://github.com/in-toto/attestation/blob/main/spec/v1/bundle.md). Other surfaces are best-effort. |

The rollout is three PRs landed back-to-back over roughly a week ([§8](#8-rollout-plan)). The `docs/SPEC.md` pointer edit is in [Appendix A](#appendix-a-docsspecmd-edit).

## TL;DR

- **Adopt AMPEL as wrangle's internal verifier and VSA issuer, but never put it on the consumer trust contract.** The signed SLSA Verification Summary Attestation (`predicateType: https://slsa.dev/verification_summary/v1`) is the only thing adopters trust; they verify it with `cosign verify-blob-attestation --new-bundle-format`, no AMPEL install required. This is the architectural split: AMPEL inside wrangle, VSA at the boundary.
- **AMPEL is the right tool for the multi-attestation job slsa-verifier cannot do**, but it is young (carabiner-dev/ampel, v1.2.1 released 2026-04-22, 49 stars at time of writing, primarily maintained by Adolfo García Veytia / @puerco, Carabiner Systems). It natively produces VSAs, supports sigstore signing, has a published GitHub Action, and a working end-to-end demo (`carabiner-dev/demo-slsa-e2e`) that does most of what wrangle wants. Conforma/Rego is a credible alternative but doesn't natively emit a VSA.
- **Ship in three back-to-back PRs over roughly a week, not a multi-quarter migration.** Front-load a policy test harness with fixture bundles, because HJSON+CEL+context bindings will drift. Reference upstream `carabiner-dev/policies` files by SHA-pinned VCS locator in the wrangle PolicySets rather than vendoring them — matches the Fritoto demo and wrangle's existing SHA-pin discipline for every other dep. Keep `slsa-verifier` as the install-time bootstrap until the final step.

## Key Findings

### 1. AMPEL is concretely capable of replacing wrangle's verify story

AMPEL ("The Amazing Multi-Purpose Policy Engine (and L)"), at `github.com/carabiner-dev/ampel`, is a Go binary plus library that:

- Consumes in-toto Statements (signed in sigstore bundles or DSSE envelopes) and evaluates **policies-as-code** written in JSON or HJSON, with executable tenets in **CEL** (`runtime: "cel@v0"`). Cedar, Rego, and JavaScript runtimes are on Carabiner's roadmap but not shipping.
- Has a first-class concept of `PolicySet` — a remote-referenceable, hash-pinnable bundle of policies (`git+https://github.com/org/repo#path/policy.json`), each of which can be linked to OSCAL controls.
- Loads attestations from pluggable **collector drivers**. The driver prefix list is not exhaustively documented; the demo, action, and source code reference at least `coci:`, `oci:`, `github:`, `jsonl:`, `fs:`, `note:`, `dnote:`, `release:`, and `http(s):`.
- Emits results in three formats via `--attest-format`: `ampel` (default; `https://carabiner.dev/ampel/resultset/v0`), **`vsa` (`https://slsa.dev/verification_summary/v1`)**, or `svr` (`https://in-toto.io/attestation/svr/v0.1`).
- Signs results via the bundled `bnd statement` tool (sigstore-keyless when in GitHub Actions via OIDC; key-based otherwise). The published action does not require an explicit `--sign` flag; signing is the default when an OIDC token is available.
- Supports **subject chaining**: a CEL selector inside a policy pivots from one in-toto subject (e.g., a binary) to another (e.g., the source commit named in its provenance) and re-fetches attestations for the chained subject. Concrete example from the demo's `fritoto-gate-publish.hjson`:

  ```
  predicates[0].data.buildDefinition.resolvedDependencies.map(
      dep, dep.uri.startsWith(context.buildPointRepo + '@'), dep)[0]
  ```

  This is the only practical way to write a single policy that simultaneously gates "binary built from SLSA Source L3 commit by a SLSA Build L3 builder with a clean OSV scan and an SBOM."
- **Transformers** are Go-compiled adapters (e.g., VEX, vuln-scanner-to-OSV) loaded on demand so one rule covers Grype/Trivy/OSV uniformly. Upstream flags the transformer framework as "still under development."
- Has a published GitHub Action at `carabiner-dev/actions/ampel/verify`, plus an installer action at `carabiner-dev/actions/install/ampel-bootstrap` (the latter uses hardcoded SHA-256 hashes as its trust root). Latest `carabiner-dev/actions` tag at time of writing is v1.2.0 (2026-05-06).

The canonical reference is `carabiner-dev/demo-slsa-e2e` ("Fritoto"), walked through in García Veytia's SLSA-foundation blog post *"SLSA End-to-End With AMPEL & Friends"* (2025-10-21). The demo performs exactly the workflow wrangle wants: verify source commit, verify builder image, gate on SBOM + OSV + VEX + test results, build, generate SLSA provenance with Tejolote, re-verify and emit per-binary VSAs, attach the VSAs to the release.

### 2. The VSA contract is portable; the AMPEL policy is not

The output VSA conforms to SLSA v1.0/v1.1 `https://slsa.dev/verification_summary/v1`. The published Fritoto sample VSA shows the full field set: `verifier.id` (e.g., `https://carabiner.dev/ampel@v1`), `timeVerified`, `resourceUri`, `policy.digest` (sha256+sha512 of the policy bytes), `verificationResult` (`PASSED`/`FAILED`), `verifiedLevels` (e.g., `SLSA_BUILD_LEVEL_3`), `dependencyLevels`, `slsaVersion: 1.1`, and `inputAttestations[]` with digests and URIs.

That format is exactly what `slsa-verifier verify-vsa` already consumes. Google publishes VSAs for GKE Container-Optimized OS images using this same flow (`cli/slsa-verifier/testdata/vsa/gce/v1/gke-gce-pre.bcid-vsa.jsonl`).

**Crucially**: nothing in the consumer-side verification path requires AMPEL. Verification works with `cosign verify-blob-attestation --bundle <artifact>.intoto.jsonl --new-bundle-format …`, or with `slsa-verifier verify-vsa`. The AMPEL-specific bits (HJSON+CEL, transformers, `predicates[].data…` runtime, `context.foo` interpolation) are *internal* to wrangle.

Whether `slsa-verifier verify-vsa` accepts an arbitrary `verifier.id` URL (e.g., `https://github.com/TomHennen/wrangle/verifier/v1`) or requires a registered identity could not be confirmed in this research pass; the matching happens in `verifiers.VerifyVSA`, which is worth reading before promising adopters a slsa-verifier-native flow. Until confirmed, **`cosign verify-blob-attestation` is the primary recommended consumer command**; slsa-verifier is documented as a secondary path.

### 3. AMPEL maturity is the dominant risk

- **Project age**: first commit January 2025; v1.2.1 released 2026-04-22; roughly monthly release cadence. `slsa-verifier`, by contrast, has been in continuous use as the canonical SLSA Build verifier since June 2022.
- **Stars / community**: 49 stars, 13 forks, primarily one author. The OSPS Baseline community-policy set is contributed back to `carabiner-dev/policies`. OpenSSF donation is *planned* per García Veytia & McNamara's *"From Mild to Wild"* session at Open Source SecurityCon Europe 2026 (Amsterdam, 2026-03-23), recapped by TLDRecap.tech, but no sandbox/incubating entry exists yet.
- **Governance**: a `GOVERNANCE.md` exists; the project is effectively single-vendor (Carabiner Systems, Apache-2.0).
- **Spec stability**: result-attestation predicate URIs include `v0` (`https://carabiner.dev/ampel/resultset/v0`); the policy schema is protobuf-generated (`carabiner-dev/policy`) and still evolving. **Wrangle pins AMPEL to a specific patch version (v1.2.1 initially), not a minor range**, and re-tests on every bump.

### 4. Alternatives considered and why AMPEL still wins for wrangle

- **Conforma** (formerly Enterprise Contract, conforma.dev): Rego/OPA-based, container-image-centric, primarily Konflux/Tekton-shaped. Robust, older than AMPEL, with a real policy library and Quay-published policy bundles. Does NOT natively emit VSAs — McNamara's OSSEU 2026 demo emitted a VSA by shimming over `ec validate image` JSON output. For wrangle's GitHub-Actions-shaped flow that needs to combine SLSA provenance + SBOM + OSV + zizmor + Scorecard into one signed VSA, Conforma is more rework than AMPEL.
- **Hand-roll in wrangle**: tempting because each policy is small. But you give up the reusable policies in `carabiner-dev/policies`, the transformer framework, the OSCAL control linking, and free signing/format handling — and you become the maintainer of yet another policy DSL.
- **OPA/Rego direct, in-toto-verifier with layouts, sigstore policy-controller**: all admission-controller-shaped, not release-gate-shaped, and don't emit VSAs by themselves. Macaron (Oracle) does emit VSAs but is tied to its own predicate types.

AMPEL natively emits a SLSA-standard VSA, natively understands sigstore-bundle attestations, ships a GitHub Action, and has a working e2e demo to crib from. No other tool checks all four boxes today.

## Details

### 5. Recommended integration architecture

#### Option A (recommended): AMPEL CLI invoked from wrangle's publish workflows; policies in-repo

**Where things live:**

- **`tools/ampel/install.sh`** — new installer mirroring `tools/osv/install.sh` (which is the closest existing pattern: download binary, fetch provenance, call `wrangle_verify_provenance`). AMPEL releases ship `ampel-v<ver>.provenance.json` as a sigstore-bundle SLSA provenance signed by `carabiner-dev/ampel`'s release workflow — `slsa-verifier verify-artifact` should accept it. If it doesn't, fall back statically to the hardcoded SHA-256 pattern used by `carabiner-dev/actions/install/ampel-bootstrap`. *Pick one statically per CLAUDE.md's "never fall back to a weaker method at runtime" rule.*

  **Why not `go install github.com/carabiner-dev/ampel/cmd/ampel@v1.2.1`?** CLAUDE.md's "Strong default: use the canonical package manager" treats `go install` as a canonical PM tier, so it has to be considered. It is rejected here because of the integrity-tier rule in the same section: SLSA provenance > GitHub release attestation > Sigstore signature > hash-pinned package manager > hardcoded SHA-256. AMPEL's upstream `ampel-v<ver>.provenance.json` is a sigstore-bundle SLSA provenance signed by Carabiner's release workflow, which is the top tier; `go install` via the Go module proxy + sum.golang.org sits at the hash-pinned-package-manager tier — per CLAUDE.md, "the sumdb attests immutability of the first-seen `(module, version)`, NOT publisher authenticity." Adopting `go install` would *downgrade* the verification AMPEL already offers, which CLAUDE.md's "NEVER fall back to a weaker tier if a stronger one fails" rule explicitly disallows. Mirroring `tools/osv/install.sh` keeps Ampel at the same SLSA-provenance tier as OSV-Scanner. The Go toolchain itself is not added to the test image for this; the upstream binary is downloaded and verified directly.
- **`policies/`** — new top-level directory holding wrangle-authored PolicySets only:
  - `policies/wrangle-default-v1.hjson` and `policies/wrangle-strict-v1.hjson` — PolicySets composed from upstream `carabiner-dev/policies` files referenced by SHA-pinned VCS locator (`git+https://github.com/carabiner-dev/policies@<sha>#slsa/slsa-builder-id.json`, etc., per Decision 2). The `context` block in each PolicySet supplies wrangle-specific bindings (builder ID regex, repo URI, expected predicate types) to the otherwise-generic upstream policies — the upstream `slsa-builder-id.json` requires a `context.builderId` input and the wrangle PolicySet provides it. Both PolicySets land in PR 1 of the rollout.
  - `policies/python-build-l3.hjson` and `policies/npm-build-l3.hjson` — concrete per-ecosystem bindings consumed by the publish workflows. Same pattern: upstream policy refs + wrangle context.
  - No vendored `_lib/` directory and no `LICENSE`/`NOTICE` copies. Apache-2.0 §4 obligations (preserve `LICENSE`, propagate `NOTICE`) apply only when redistributing the licensed work; SHA-pinned references are not redistribution. If a future change actually forks an upstream policy — e.g., to add a CEL clause upstream rejects — that fork moves into `policies/_lib/` and the licensing obligation kicks in at that point; until then there is nothing to vendor. See §10 for the redistribution-by-reference assumption being relied on.
- **`policies/testdata/`** — fixture attestation bundles (`good-*.jsonl`, `bad-*-missing-sbom.jsonl`, etc.) plus golden VSAs. A new bats target runs `ampel verify` against fixtures and asserts verification result and `verifiedLevels`. **This is the single most important PR 1 deliverable** — HJSON+CEL+context drift is silent otherwise. Bats matches existing wrangle test style; no Go dependency.
- **`actions/verify/action.yml`** — new composite action that takes `subject`, `policy`, `collector`, and calls `carabiner-dev/actions/ampel/verify@<sha>` with `--attest-format=vsa --push-attestation=true`. Uploads the VSA as a workflow artifact and (on tagged releases) attaches it to the GitHub release.
- **Scanner outputs** continue to come out of `actions/scan` as today; each scanner's adapter is augmented to wrap its SARIF in an in-toto Statement (via `bnd predicate`/`bnd statement`) and append to `.attestations/attestations.bundle.jsonl`. That bundle is the input to verify. The SARIF predicate type is **not standardized** in `in-toto/attestation` (the vetted list as of 2026-05: CycloneDX, Link, Reference, Release, Runtime Traces, SCAI Report, SLSA Provenance, SLSA VSA, SPDX2, SPDX3, Simple Verification Result, Test Result, VULNS — no SARIF). **Decision: wrangle defines `https://github.com/TomHennen/wrangle/attestation/sarif/v0.1` and uses it for the zizmor / OSV / Scorecard SARIF wrapping.** Same namespace shape as the `verifier.id` (§6). Upstreaming to `in-toto/attestation` is a v1.0 work item if anyone outside wrangle adopts it.

**Where the VSA gets signed and published:**

- **Signing:** sigstore keyless via GitHub OIDC, by the published `carabiner-dev/actions/ampel/verify` action (no custom flag wrapping required — the action calls `bnd statement` internally when an OIDC token is available). The verifier identity is the wrangle release workflow's Fulcio cert (`https://github.com/TomHennen/wrangle/.github/workflows/verify.yml@refs/tags/v.+`). Treat this workflow path as part of the public API.
- **Publishing (Decision 4):** the canonical sink is a GitHub release asset named per the [in-toto v1 bundle convention](https://github.com/in-toto/attestation/blob/main/spec/v1/bundle.md): `<artifact>.intoto.jsonl` (a sigstore-bundle DSSE envelope per line). Ampel's own CLI default is `ampel.intoto.json` (single statement); the wrangle composite action renames to `<artifact>.intoto.jsonl` on publish to match the in-toto bundle spec — the convention adopters can rely on without learning Ampel-specific naming. The verify action also pushes to the GH attestations store (`gh attestation verify` works for free) and uploads the VSA as a workflow artifact for debugging. If the three diverge, the release asset wins.

**Policy evaluation runs in two stages**, mirroring Fritoto:

1. **Pre-build gate** (`fritoto-gate-build`-shaped): SBOM exists, OSV scan clean modulo VEX, tests pass, zizmor clean, source commit attestations verify. Runs in the publish workflow before the build step. The result is not released — it just blocks the workflow.
2. **Pre-publish gate** (`fritoto-gate-publish`-shaped, 5 policies in the real demo): SLSA Build provenance verifies (`slsa-builder-id`, `slsa-build-type`, `slsa-build-point`), source commit chains to a SLSA Source attestation, builder image chains to a SLSA Build L3 VSA. **This is the VSA wrangle signs and publishes.**

**Tradeoffs:** clean separation of concerns; wrangle PolicySets are reviewable as PRs; the bats harness catches drift; bootstrap stays `slsa-verifier` (transitional); upstream policy bumps are a single SHA edit (no vendor refresh). Cons: two AMPEL invocations per release; slightly more CI minutes; each verify resolves the upstream `git+https://` reference, so a `github.com` outage breaks CI (mitigation in §10 risk 6).

#### Option B: AMPEL as a Go library linked into a small wrangle CLI

Use `github.com/carabiner-dev/policy` and `github.com/carabiner-dev/ampel/pkg/verifier` directly. Wrangle ships a small `wrangle-verify` binary that compiles policies in and emits a VSA. Preferable only if wrangle wants embedded policies (no remote fetch ever) or wrangle-specific CEL functions. Cost: turns wrangle into a Go project (currently shell + composite actions only) and depends on internal packages clearly evolving (`carabiner-dev/policy/api/v1/`). **Not recommended for the initial rollout.**

#### Option C: Separate verifier service/repo that issues VSAs out-of-band

Closer to Google's BCID model. Formally correct under SLSA L3 (the builder MUST NOT be the verifier of its own provenance — *"for demonstration purposes, the build process is running Tejolote in the same job, which is not ideal (or SLSA 3 compliant)"*, per the SLSA E2E blog). For wrangle's current threat model, Option A is a defensible pragmatic choice; the L3 separation gap is documented in [Appendix A](#appendix-a-docsspecmd-edit)'s SPEC.md edit as a known limitation. **Re-evaluate when wrangle adopters formally require builder/verifier separation, post-v1.0.**

**Recommendation:** Option A for the three-PR rollout. Reopen Option C as a v1.0+ work item.

### 6. Recommended default policy outline

Two PolicySets in `policies/`, each composed from upstream `carabiner-dev/policies` files (referenced by SHA-pinned VCS locator per Decision 2) plus wrangle-authored tenets for the gaps upstream doesn't cover.

#### `wrangle-default-v1`

Subject: the release artifact (sha256 of tarball/wheel/tgz/image). Tenets (AND-mode):

1. **SLSA Build provenance present and valid.** Upstream `carabiner-dev/policies#slsa/slsa-builder-id.json`, `slsa/slsa-build-type.json`, `slsa/slsa-build-point.json` (the three policies the Fritoto `gate-publish` set uses for build provenance), each referenced as `git+https://github.com/carabiner-dev/policies@<sha>#…` with the same SHA pin across the three. Wrangle context binds the builder identity to `https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_*` (or the language-specific generator) and source repo URI to `github.repository`.
2. **Source commit verifies.** *(Gated on [#174](https://github.com/TomHennen/wrangle/issues/174) — wrangle does not emit a SLSA Source attestation today.)* Upstream `carabiner-dev/policies#vsa/slsa-source-level3.json` with the chain-to-source-commit CEL pattern from `fritoto-gate-publish.hjson` (see §1 quote). Until #174 lands, this tenet is omitted from `wrangle-default-v1` and the emitted VSA does not claim `SLSA_SOURCE_LEVEL_*`; the rest of the policy ships independently.
3. **SBOM present.** Upstream `carabiner-dev/policies#sbom/sbom-exists.json` against an SPDX or CycloneDX predicate attached to the artifact.
4. **OSV scan clean modulo VEX.** Upstream `carabiner-dev/policies#openvex/no-exploitable-vulns-osv.json` with the VEX transformer.
5. **zizmor SARIF clean.** Wrangle-authored policy under the wrangle SARIF predicate type (see §5 SARIF note) — lives directly in `policies/` (no upstream equivalent yet).
6. **Sigstore signature on the artifact.** Wrangle workflow OIDC identity expected as signer. Wrangle-authored.

Emits VSA with `verifiedLevels: ["SLSA_BUILD_LEVEL_3"]` (assuming slsa-github-generator is used), `verifier.id: https://github.com/TomHennen/wrangle/verifier/v1`, `resourceUri` set to the artifact's purl, `policy.uri` and `policy.digest` recording the SHA-pinned wrangle policy reference and content digest.

#### `wrangle-strict-v1`

Additive over default: Scorecard ≥ 7; no HIGH/CRITICAL OSV findings even with VEX; declared tool dependencies (Syft, OSV-Scanner, AMPEL) themselves have valid VSAs at SLSA_BUILD_LEVEL_3 (chained subjects); reproducible/hermetic build attestation where the language ecosystem supports it.

`wrangle-strict-v1` is the policy wrangle itself dogfoods on its own releases.

### 7. Downstream consumer UX

Three layers, documented in `build/actions/{python,npm,container}/README.md`:

**Layer 1 (default, recommended for most consumers): verify the VSA only.**

```bash
gh release download v1.2.3 --repo my-org/my-app -p '*.intoto.jsonl' -p 'my-app-*.tgz'
cosign verify-blob-attestation \
  --bundle my-app-1.2.3.tgz.intoto.jsonl \
  --new-bundle-format \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp="^https://github.com/TomHennen/wrangle/.github/workflows/verify\\.yml@refs/tags/v.+" \
  my-app-1.2.3.tgz
```

A `slsa-verifier verify-vsa` flow is also possible once we confirm it accepts our `verifier.id`; the consumer doc should document `cosign verify-blob-attestation` first and `slsa-verifier verify-vsa` as a secondary option pending that confirmation.

**Layer 2 (for paranoid consumers): re-run the full verification.** Install AMPEL, point at the same release, pass the same policy. (Most adopters won't.)

**Layer 3 (tooling integrators): consume the VSA inside their own admission policy** — the standard SLSA dependency-VSA pattern. The upstream `carabiner-dev/policies` `vsa/` directory already has exemplars.

**Trust chain consumers internalize**: (1) sigstore public-good root (industry standard); (2) the wrangle workflow OIDC identity (regex on the verify workflow path); (3) the policy SHA-256 in `policy.digest`. Three things, none AMPEL-specific.

### 8. Rollout plan

Three back-to-back PRs, landing over roughly a week. The plan is sequential because PR 2 wires the action PR 1 ships, and PR 3 swaps the install-time helper PR 2 starts using. Each PR is independently reviewable and revertable; none should sit in flight for more than two or three days.

| PR | What ships | slsa-verifier status |
|----|------------|---------------------|
| **PR 1 — Foundations** | `tools/ampel/install.sh` (mirrors `tools/osv/install.sh`); `actions/verify/action.yml` composite wrapping `carabiner-dev/actions/ampel/verify`; `policies/wrangle-default-v1.hjson` + `policies/wrangle-strict-v1.hjson` referencing upstream `carabiner-dev/policies` by SHA-pinned VCS locator; `policies/testdata/` fixtures and bats harness; SARIF in-toto wrapping helper used by zizmor / OSV / Scorecard adapters. | Installed alongside; unchanged. |
| **PR 2 — Publish workflows + consumer docs** | Wire `actions/verify` into Python, npm, and container publish workflows; emit signed VSA on every tagged release as `<artifact>.intoto.jsonl`; document `cosign verify-blob-attestation` flow in `build/actions/{python,npm,container}/README.md`; container path replaces the separate `cosign verify` + `slsa-verifier verify-image` step in `build/actions/container/SPEC.md:153`. | Runs in parallel with AMPEL for one tagged release. If both pass, PR 3 removes it from the publish paths. |
| **PR 3 — Bootstrap swap** | Rewrite `lib/download_verify.sh:84` (`wrangle_verify_provenance`) to call AMPEL with a tool-install policy; OSV/Syft installers pick up the new helper transparently; remove the `slsa-verifier` install step from `actions/scan/action.yml:25-26` and the parallel run from the publish workflows. | Removed from the codebase. |

The `slsa-verifier` install-time bootstrap stays through PR 2 because wrangle's own AMPEL installer relies on it to verify Ampel's provenance bundle; it's removed in PR 3 once AMPEL itself can verify the next AMPEL release. Self-verification through AMPEL's own SLSA provenance is elegant but adds a moving part exactly where wrangle wants the least magic — the release-blocker installer. Simplicity beats symmetry, so the swap happens once and only after the publish paths have shipped a clean release.

**What this plan deliberately drops.** The earlier scoping draft split the work into seven phases stretching across "this quarter" and "next quarter" — separate phases for python vs. npm publish, separate phases for multi-attestation wiring, separate phases for versioned PolicySets and consumer docs. None of that sequencing is forced by the technology: the multi-attestation policy, the per-language wiring, the versioned PolicySets, and the consumer docs are all small, independent edits that can ship in one PR (PR 2) with a single review. Splitting them only buys a longer calendar.

### 9. Key files in wrangle that change

| File | Change |
|---|---|
| `actions/scan/action.yml:25-26` | PR 1: add `tools/ampel/install.sh` step alongside slsa-verifier install. PR 3: remove slsa-verifier installer. |
| `lib/download_verify.sh:84` (`wrangle_verify_provenance`) | PR 3: rewrite to invoke `ampel verify` with a tool-install policy. |
| `tools/ampel/install.sh` | New in PR 1 — mirrors `tools/osv/install.sh`. |
| `tools/osv/install.sh:69`, `tools/syft/install.sh:112` | PR 3: `osv` currently calls `wrangle_verify_provenance` (SLSA path) and `syft` currently calls `wrangle_download_verify` (checksum path); both follow `lib/download_verify.sh` into AMPEL when that helper is rewritten. |
| `.github/workflows/build_and_publish_python.yml:243-251` | PR 2: replace `slsa-verifier verify-artifact` with AMPEL verify + VSA emit (parallel run with slsa-verifier for one release). |
| `.github/workflows/build_and_publish_npm.yml:241-249` | PR 2: same. |
| `policies/` (new) | PR 1: HJSON PolicySets referencing upstream `carabiner-dev/policies` by SHA-pinned VCS locator + `testdata/` fixtures. |
| `actions/verify/action.yml` (new) | PR 1: composite action wrapping `carabiner-dev/actions/ampel/verify`. |
| `build/actions/{python,npm,container}/README.md` | PR 2: document `cosign verify-blob-attestation` consumer flow. |
| `build/actions/container/SPEC.md:153` | PR 2: replace the separate `cosign verify` + `slsa-verifier verify-image` row with a single-VSA flow. |
| `docs/SPEC.md:1046` | This scoping PR: replace the v0.2.0 Ampel bullet with a pointer to this doc and a tracking link. See [Appendix A](#appendix-a-docsspecmd-edit). |

### 10. Risks and open questions

**Risks (ordered by severity):**

1. **AMPEL policy schema instability.** `carabiner-dev/policy` is at v1 but rapidly evolving with one primary maintainer. *Mitigation:* patch-pin AMPEL (Decision: v1.2.1); SHA-pin every upstream `carabiner-dev/policies` reference in the wrangle PolicySets (Decision 2) so a breaking upstream change cannot reach wrangle's CI without an explicit SHA bump in this repo; fixture-based bats harness in `policies/testdata/`.
2. **Single-vendor governance.** AMPEL is effectively a Carabiner Systems project. OpenSSF donation is planned but unconfirmed. *Mitigation:* consumers depend only on VSA, not on AMPEL — engine substitution stays contained.
3. **CEL expressivity in unfamiliar territory.** Writing CEL that traverses `predicates[0].data.…` with `context.foo` is debuggable but unfamiliar. *Mitigation:* heavy HJSON commenting; `error.guidance` on each tenet; render results as Markdown into `$GITHUB_STEP_SUMMARY` (GitHub Actions renders step summaries as Markdown natively; HTML is accepted but Markdown is the documented format). If Ampel only exposes `--format=html`, the wrapping action converts to a Markdown table before writing the summary.
4. **VSA signing-identity churn.** If the wrangle verify workflow path changes, adopters' `--certificate-identity-regexp` breaks. *Mitigation:* commit to a stable identity regex from day one; treat `verify.yml`'s path as part of the public API; consider a thin wrapper repo for stable identity (the `slsa-framework/source-actions` model) only if it bites.
5. **Repo-rename churn for `verifier.id` and the SARIF predicate type.** Both use `https://github.com/TomHennen/wrangle/...` because no `wrangle.dev`/`wrangle.io` domain is available. If the repo is later renamed or donated (the v1.0 OpenSSF goal), adopters' policies that pin the current URI break. *Mitigation:* treat this as a `v1` → `v2` bump event (Decision 4 rule in §6): only break consumers when a previously-passing artifact would now fail. Continue emitting `v1` URIs for the old policy during a transition window if needed. Grabbing a project-owned domain remains the cleanest long-term fix and is worth a passing attempt before v1.0.
6. **Network dependency on `github.com` at verify time.** Referencing upstream policies by `git+https://github.com/carabiner-dev/policies@<sha>#…` (Decision 2) means a `github.com` outage breaks a release. *Mitigation:* the same runner already requires `github.com` for `actions/checkout` and to push attestations, so this does not expand the failure surface; if `github.com` is down, the workflow has nothing to attest about anyway. If a future operational reason demands an air-gapped verify (e.g., a customer-controlled runner), the escape hatch is to fork an upstream policy into a `policies/_lib/` tree — at which point the Apache-2.0 §4(a)/§4(c) `LICENSE`/`NOTICE` obligation that we deliberately avoid here kicks in. The fixture-bats harness in `policies/testdata/` does not need network either way (collectors point at local files via the `jsonl:` driver). CEL evaluation itself is fast; the dominant verify-time cost is collector network calls to fetch attestations, not policy fetch.
7. **Failure-mode opacity.** If AMPEL can't fetch a referenced attestation, today's CI-readable error story is uneven. *Mitigation:* render results as Markdown into `$GITHUB_STEP_SUMMARY` (see risk 3); the verify action dumps the attestations bundle on failure.
8. **Pin drift across files.** Two distinct pins live in multiple places. (a) The Ampel v1.2.1 pin appears in `tools/ampel/install.sh` (binary version + hardcoded SHA-256 fallback), `actions/verify/action.yml` (`carabiner-dev/actions/ampel/verify@<sha>`), and the verifier-identity regex in adopter-facing docs. (b) The `carabiner-dev/policies` SHA pin from Decision 2 appears in every wrangle PolicySet that references upstream files — `wrangle-default-v1.hjson`, `wrangle-strict-v1.hjson`, and the per-ecosystem PolicySets — and the pins must stay in lockstep across them, otherwise different policies in the same evaluation could pull from different upstream snapshots. CLAUDE.md's "Pins drift across files" rule applies to both. *Mitigation:* either consolidate each to a single source (a `tools/ampel/VERSION` file for (a); a `policies/UPSTREAM_SHA` file substituted into the PolicySets at evaluation time for (b)) or add a regression test that diffs the locations and fails on divergence, following the `make bump-action-pins` / pins-drift test precedent already in the repo. A simple `make bump-policies` shim that rewrites the SHA across all PolicySet files in one pass is enough if Dependabot can't reach the VCS-locator URI directly.

**Open questions remaining for the implementation issues:**

- **slsa-verifier verify-vsa matching:** does it accept an arbitrary `verifier.id` URL, or require allowlisting? (Read `verifiers.VerifyVSA`.) Affects whether Layer-1 consumer docs offer a slsa-verifier-native command.
- **AMPEL provenance verification:** does `slsa-verifier verify-artifact` accept the sigstore-bundle format AMPEL ships at `ampel-v<ver>.provenance.json`? If not, PR 1 falls back to the hardcoded-SHA pattern.
- **VSA `inputAttestations[].uri` portability:** does the URI survive repo rename or release-asset deletion? (Pull a real Fritoto VSA and check.)

## Recommendations

**Do, in order (~1 week end-to-end):**
1. Land this scoping doc and the `docs/SPEC.md` edit ([Appendix A](#appendix-a-docsspecmd-edit)). Review focuses on the four Decisions and the §8 rollout plan.
2. Land PR 1 (foundations): `tools/ampel/install.sh`, `actions/verify`, `wrangle-default-v1` + `wrangle-strict-v1` referencing upstream `carabiner-dev/policies` by SHA-pinned VCS locator, fixtures-based bats harness, SARIF in-toto wrapping.
3. Land PR 2 (publish wiring + consumer docs): wire `actions/verify` into Python, npm, and container publish; emit `<artifact>.intoto.jsonl` on tagged releases; document the `cosign verify-blob-attestation` flow. Run alongside `slsa-verifier` for one release.
4. Land PR 3 (bootstrap swap): rewrite `wrangle_verify_provenance` to call AMPEL; remove `slsa-verifier` from the scan action and the publish workflows.

**Re-evaluate when:**
- AMPEL is donated to OpenSSF, or its schema bumps to v2 — review schema migration, consider Option B library mode.
- An exploit or wide outage in `carabiner-dev/ampel` — invoke the engine-swap option (VSA contract is portable; consumer impact zero).
- SLSA v1.2+ introduces additional VSA fields — bump `wrangle-default-v2`.
- [#174](https://github.com/TomHennen/wrangle/issues/174) lands and wrangle emits a SLSA Source attestation — add the source-commit tenet currently gated out of `wrangle-default-v1` (§6).

**Do not:**
- Require consumers to install AMPEL. The VSA is the only consumer contract.
- Block PR 3 (slsa-verifier removal) on perfection of PRs 1–2. If PR 2 ships a clean release in parallel, PR 3 is safe.
- Delay shipping PR 1 waiting for OpenSSF donation or v2 schema.

## Caveats

- **AMPEL is genuinely young.** The architecture in this report (AMPEL internal, VSA external) explicitly bets on the engine being swappable. If that bet is broken — e.g., by exposing AMPEL-specific semantics to consumers — the risk profile changes substantially.
- **The OpenSSF donation is a stated plan, not a fait accompli.** Do not let the migration plan depend on it.
- **Some upstream policy file contents and exact CEL strings** (e.g., the body of `carabiner-dev/policies#vsa/slsa-source-level3.json`) were not retrieved verbatim in this research pass. Before authoring `policies/wrangle-default-v1.hjson`, pull the files at the SHA we plan to pin and read them; they document the `context` inputs each one requires and are the source of truth for whatever bindings the wrangle PolicySet must supply.
- **SLSA v1.1 is the current approved spec.** VSA predicate type `https://slsa.dev/verification_summary/v1` is the right target.
- **Option A technically violates SLSA L3 builder/verifier separation**, as the Fritoto blog itself acknowledges for Tejolote-in-same-job. Documented in [Appendix A](#appendix-a-docsspecmd-edit)'s SPEC edit as a known limitation; reopen post-v1.0 (Option C).
- **The sigstore keyless trust chain is the dominant trust assumption.** If an adopter needs an air-gapped path, AMPEL's `--signing-backend=key` works but requires wrangle to publish and rotate a public key.

## Revision history

**Revision 5 — 2026-05-28:** Reversed Decision 2: dropped vendoring of `carabiner-dev/policies` entirely in favour of SHA-pinned VCS-locator references (`git+https://github.com/carabiner-dev/policies@<sha>#…`) inside the wrangle-authored PolicySets. Triggered by the question "is vendoring really necessary?" — investigation showed (a) Ampel natively supports VCS locators via `carabiner-dev/vcslocator` and the verify flag is documented as "(h)json source location (file path, URL, or VCS locator)", (b) the upstream `carabiner-dev/policies` files (`slsa-builder-id.json`, `sbom-exists.json`, etc.) are generic and parameterized via `context` inputs — no wrangle-specific edits required, (c) the canonical Fritoto demo (`policies/fritoto-gate-publish.hjson`) references upstream policies by VCS locator, not by vendored copy. Vendoring would diverge from both upstream practice and wrangle's own SHA-pin convention for every other dep. Knock-on edits: §5 dropped `policies/_lib/`, dropped the Apache-2.0 §4 `LICENSE`/`NOTICE` paragraph (no redistribution → no §4 obligation), and rewrote each `policies/` bullet around wrangle-authored PolicySets only; §6 rewrote each tenet to reference upstream policies by `git+https://…@<sha>#path` rather than `_lib/` paths; §8 PR 1 row and §9 file table dropped vendored-lib language; §10 risk 1 mitigation switched from vendoring to SHA-pinning the upstream refs; §10 risk 6 ("Performance") repurposed as "Network dependency on `github.com` at verify time" with the operational justification (the runner needs `github.com` for `actions/checkout` anyway) and a documented escape hatch (fork to `policies/_lib/` only if a future air-gapped requirement appears, at which point the Apache-2.0 obligation kicks in); §10 risk 8 (pin drift) extended to cover the new `carabiner-dev/policies` SHA pin that lives in every PolicySet that references it. `make update-policies` deleted from the plan — replaced by an optional `make bump-policies` shim if Dependabot can't reach VCS-locator URIs. Caveats note about retrieving upstream policy contents updated from "vendor the actual files" to "pull at the SHA we plan to pin and read them".

**Revision 4 — 2026-05-28:** §8 collapsed from a seven-phase, multi-quarter migration into a three-PR rollout over roughly a week (foundations → publish wiring + consumer docs → bootstrap swap); §9 and Recommendations rewritten to match. §6 source-commit tenet now explicitly gated on [#174](https://github.com/TomHennen/wrangle/issues/174) and dropped from `wrangle-default-v1` until SLSA Source ships. VSA file extension switched from the invented `*.vsa.sigstore.json` to the [in-toto v1 bundle](https://github.com/in-toto/attestation/blob/main/spec/v1/bundle.md) standard `<artifact>.intoto.jsonl`; consumer download example and Decision 4 updated. §5 vendored-policy bullet now spells out the Apache-2.0 licensing obligation (preserve upstream `LICENSE`/`NOTICE`); same point cross-referenced from Decision 2. §10 risks 3 and 7: step-summary rendering switched from `--format=html` to Markdown (GitHub Actions step summaries are Markdown-native). Self-referential "tighten #247" / "as issue #247 outlines" / "this is the split issue #247 proposed" framing rewritten as direct statements throughout.

**Revision 3 — 2026-05-28:** §5 now explicitly considers and rejects `go install` for Ampel against CLAUDE.md's integrity-tier ladder; §10 adds a "Pin drift across files" risk pointing at the `make bump-action-pins` precedent; §10 risk numbering corrected from `1,2,3,4,7,5,6` to sequential; inline `*[Revision N …]*` parentheticals stripped throughout (history lives only in this section, per CLAUDE.md "no narrating history").

**Revision 2 — 2026-05-26:**

- **Factual fixes against upstream:**
  - Install action renamed `install/ampel` → `install/ampel-bootstrap`.
  - Community-policy set path `sets/osps-baseline/` → `sets/baseline/` (referenced indirectly; concrete `_lib/` vendor paths use the per-domain dirs `slsa/`, `vsa/`, `sbom/`, `openvex/`).
  - Collector-prefix list now matches what is confirmed in upstream; `ossrebuild:` removed pending confirmation.
  - OSSNA 2025 bio quote about García Veytia removed (unverifiable in the published bio).
  - `carabiner-dev/actions` version: noted v1.2.0 (2026-05-06); pin policy is patch-level.
  - AMPEL ships `ampel-v<ver>.provenance.json` as a sigstore-bundle SLSA provenance — bootstrap design now uses this with `wrangle_verify_provenance`.
  - `ampel/verify` action does **not** require explicit `--sign --sigstore-oidc-token-file` wrapping; signing is built in via `bnd statement`.
- **In-repo citation fixes:**
  - `docs/SPEC.md:1036` → `docs/SPEC.md:1046`.
  - §9 table corrected for `tools/osv/install.sh` and `tools/syft/install.sh` (both already source `lib/download_verify.sh`; only the helper changes).
- **Internal contradictions resolved:**
  - AMPEL version: patch-pin v1.2.1 (not "pin minor").
  - Policy distribution Phase 1: checked-in HJSON + vendored `_lib/` (no remote `git+https://` fetch at runtime).
  - parallel-correctness vs install-bootstrap roles for slsa-verifier disambiguated in §8.
  - "Release cycle" = one wrangle tagged release.
  - Test harness: bats only (drop Go wrapper).
  - VSA signing identity: use the published action's defaults (no custom wrap).
- **Structural additions:**
  - "Decisions" block up front, answering #247's AC.
  - Appendix A (SPEC.md edit) added. Tracking stays on a single issue (#247); each phase becomes a PR rather than its own issue.
- **Scope trims:** `wrangle-strict-v1` detail compressed; Option B/C reduced to one paragraph each; container-VSA detail referred to Phase 6 of the §8 plan.

**Revision 1 — initial cloud-agent research pass.**

---

## Appendix A: docs/SPEC.md edit

Replace the existing v0.2.0 bullet at `docs/SPEC.md:1046`:

```diff
-- [ ] [Ampel](https://github.com/carabiner-dev/ampel) integration — policy verification layer that evaluates attestations against CEL-based policies and produces Verification Summary Attestations
+- [ ] [Ampel](https://github.com/carabiner-dev/ampel) integration — policy
+      verification layer that evaluates attestations against CEL-based
+      policies and produces Verification Summary Attestations. Scoping in
+      [`docs/ampel_research.md`](./ampel_research.md); rollout is three
+      PRs (foundations, publish wiring + consumer docs, bootstrap swap).
+      Known limitation: the rollout keeps the build workflow and the
+      verifier in the same GitHub Actions job, which is not strictly
+      SLSA L3-compliant for builder/verifier separation. A separate
+      verifier service (Option C in the scoping doc) is a post-v1.0
+      work item.
```

No other SPEC.md changes are required for the scoping step; further SPEC edits land with each rollout PR.
