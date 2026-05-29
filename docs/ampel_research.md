# Integrating Ampel into wrangle: Design Analysis and Implementation Plan

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Bootstrap:** keep `slsa-verifier` as wrangle's install-time trust anchor through the final step of the rollout. | AMPEL ships a sigstore-bundle SLSA provenance (`ampel-v1.2.1.provenance.json`) that `wrangle_verify_provenance` already knows how to verify. Adding a self-verify dance buys nothing. |
| 2 | **Policy distribution:** wrangle authors the `wrangle-default-v1` and `wrangle-strict-v1` PolicySets in `policies/`. They reference upstream `carabiner-dev/policies` files by SHA-pinned VCS locator (`git+https://github.com/carabiner-dev/policies@<sha>#slsa/slsa-builder-id.json`). No vendored copies. Dependabot — or a `make bump-policies` shim if Dependabot can't reach the URI — bumps the SHA across all PolicySets atomically. | Mirrors wrangle's SHA-pin discipline for every other upstream dep, matches the Fritoto demo's own reference pattern, and avoids the Apache-2.0 `LICENSE`/`NOTICE` redistribution obligation that vendoring would carry. Trade-off: Ampel resolves the locator on each verify, so the runner needs network access to `github.com` (already required for `actions/checkout`). |
| 3 | **VSA signing identity:** sigstore keyless via GitHub OIDC, using `carabiner-dev/actions/ampel/verify` as published — no custom signing wrapper. | The published action already signs results via `bnd statement`, matching `slsa-github-generator`'s identity model. Adopters verify with a stable workflow-path regex. |
| 4 | **VSA storage:** GitHub release asset is the canonical artifact, named per the in-toto v1 bundle convention (`<artifact>.intoto.jsonl`). Workflow-artifact and `gh attestation` store are redundant convenience copies. | Adopters can `wget` the release asset without GitHub auth; the `.intoto.jsonl` name matches the [in-toto attestation bundle spec](https://github.com/in-toto/attestation/blob/main/spec/v1/bundle.md). Other surfaces are best-effort. |

The rollout is three PRs landed back-to-back over roughly a week ([§8](#8-rollout-plan)). The `docs/SPEC.md` pointer edit is in [Appendix A](#appendix-a-docsspecmd-edit).

## TL;DR

- **AMPEL inside wrangle, VSA at the boundary.** Adopters trust only the signed SLSA Verification Summary Attestation (`predicateType: https://slsa.dev/verification_summary/v1`) and verify it with `cosign verify-blob-attestation --new-bundle-format`. No AMPEL install required downstream.
- **AMPEL is the right engine for the multi-attestation job slsa-verifier cannot do.** It natively emits VSAs, signs via sigstore, ships a GitHub Action, and has a working e2e demo (`carabiner-dev/demo-slsa-e2e`). It is also young — v1.2.1, ~49 stars, primarily one maintainer ([§3](#3-ampel-maturity-is-the-dominant-risk)). Conforma is the credible alternative but doesn't natively emit a VSA ([§4](#4-alternatives-considered-and-why-ampel-still-wins-for-wrangle)).
- **Ship in three back-to-back PRs over roughly a week, not a multi-quarter migration** ([§8](#8-rollout-plan)).

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

Nothing in the consumer-side verification path requires AMPEL: verification works with `cosign verify-blob-attestation --bundle <artifact>.intoto.jsonl --new-bundle-format …` or `slsa-verifier verify-vsa`. The AMPEL-specific bits (HJSON+CEL, transformers, `predicates[].data…` runtime, `context.foo` interpolation) are *internal* to wrangle. This is the architectural split the rollout bets on — keep it intact and the engine stays swappable.

Whether `slsa-verifier verify-vsa` accepts an arbitrary `verifier.id` URL (e.g., `https://github.com/TomHennen/wrangle/verifier/v1`) or requires a registered identity could not be confirmed in this research pass; the matching happens in `verifiers.VerifyVSA`, which is worth reading before promising adopters a slsa-verifier-native flow. Until confirmed, **`cosign verify-blob-attestation` is the primary recommended consumer command**; slsa-verifier is documented as a secondary path.

### 3. AMPEL maturity is the dominant risk

- **Project age**: first commit January 2025; v1.2.1 released 2026-04-22; roughly monthly release cadence. `slsa-verifier`, by contrast, has been in continuous use as the canonical SLSA Build verifier since June 2022.
- **Stars / community**: 49 stars, 13 forks, primarily one author (Adolfo García Veytia / @puerco, Carabiner Systems). The OSPS Baseline community-policy set is contributed back to `carabiner-dev/policies`. OpenSSF donation is *planned* per García Veytia & McNamara's *"From Mild to Wild"* session at Open Source SecurityCon Europe 2026 (Amsterdam, 2026-03-23), recapped by TLDRecap.tech, but no sandbox/incubating entry exists yet.
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

- **`tools/ampel/install.sh`** — new installer mirroring `tools/osv/install.sh` (download binary, fetch provenance, call `wrangle_verify_provenance`). AMPEL releases ship `ampel-v<ver>.provenance.json` as a sigstore-bundle SLSA provenance; `slsa-verifier verify-artifact` should accept it. If it doesn't, fall back statically to the hardcoded SHA-256 pattern used by `carabiner-dev/actions/install/ampel-bootstrap`. *Pick one statically per CLAUDE.md's "never fall back to a weaker method at runtime" rule.*

  **Why not `go install github.com/carabiner-dev/ampel/cmd/ampel@v1.2.1`?** CLAUDE.md's "Strong default: use the canonical package manager" makes `go install` a candidate, but its integrity-tier rule rejects it here: AMPEL's sigstore-bundle SLSA provenance sits at the top tier; `go install` via the Go module proxy + sum.golang.org sits at the hash-pinned-package-manager tier — per CLAUDE.md, "the sumdb attests immutability of the first-seen `(module, version)`, NOT publisher authenticity." Adopting `go install` would *downgrade* verification, which the "NEVER fall back to a weaker tier" rule disallows. Mirroring `tools/osv/install.sh` keeps Ampel at the same SLSA-provenance tier as OSV-Scanner.
- **`policies/`** — new top-level directory holding wrangle-authored PolicySets (per Decision 2, all upstream refs are SHA-pinned VCS locators; no vendored `_lib/`, no `LICENSE`/`NOTICE` copies):
  - `policies/wrangle-default-v1.hjson` and `policies/wrangle-strict-v1.hjson` — composed from upstream `carabiner-dev/policies` files. The `context` block in each PolicySet supplies wrangle-specific bindings (builder ID regex, repo URI, expected predicate types) to the otherwise-generic upstream policies. Both land in PR 1.
  - `policies/python-build-l3.hjson` and `policies/npm-build-l3.hjson` — concrete per-ecosystem bindings consumed by the publish workflows.
  - If a future change actually forks an upstream policy — e.g., to add a CEL clause upstream rejects — that fork moves into `policies/_lib/` and the Apache-2.0 §4(a)/§4(c) obligation kicks in at that point (see §10 risk 6).
- **`policies/testdata/`** — fixture attestation bundles (`good-*.jsonl`, `bad-*-missing-sbom.jsonl`, etc.) plus golden VSAs. A new bats target runs `ampel verify` against fixtures and asserts result and `verifiedLevels`. **This is the single most important PR 1 deliverable** — HJSON+CEL+context drift is silent otherwise. Bats matches existing wrangle test style; no Go dependency.
- **`actions/verify/action.yml`** — new composite action that takes `subject`, `policy`, `collector`, and calls `carabiner-dev/actions/ampel/verify@<sha>` with `--attest-format=vsa --push-attestation=true`. Uploads the VSA as a workflow artifact and (on tagged releases) attaches it to the GitHub release.
- **Scanner outputs** continue to come out of `actions/scan` as today; each scanner's adapter is augmented to wrap its SARIF in an in-toto Statement (via `bnd predicate`/`bnd statement`) and append to `.attestations/attestations.bundle.jsonl`. The SARIF predicate type is **not standardized** in `in-toto/attestation` (the vetted list as of 2026-05 covers CycloneDX, Link, Reference, Release, Runtime Traces, SCAI Report, SLSA Provenance, SLSA VSA, SPDX2, SPDX3, Simple Verification Result, Test Result, VULNS — no SARIF). **Decision: wrangle defines `https://github.com/TomHennen/wrangle/attestation/sarif/v0.1` and uses it for the zizmor / OSV / Scorecard SARIF wrapping.** Same namespace shape as the `verifier.id` (§6). Upstreaming to `in-toto/attestation` is a v1.0 work item if anyone outside wrangle adopts it.

**Signing and publishing:** see Decisions 3 and 4. The verifier identity is the wrangle release workflow's Fulcio cert (`https://github.com/TomHennen/wrangle/.github/workflows/verify.yml@refs/tags/v.+`); treat this workflow path as part of the public API. The composite action renames Ampel's default `ampel.intoto.json` (single statement) to `<artifact>.intoto.jsonl` on publish, matching the in-toto bundle convention. The action also pushes to the GH attestations store and uploads a workflow artifact; if the three diverge, the release asset wins.

**Policy evaluation runs in two stages**, mirroring Fritoto:

1. **Pre-build gate** (`fritoto-gate-build`-shaped): SBOM exists, OSV scan clean modulo VEX, tests pass, zizmor clean, source commit attestations verify. Runs in the publish workflow before the build step. The result is not released — it just blocks the workflow.
2. **Pre-publish gate** (`fritoto-gate-publish`-shaped, 5 policies in the real demo): SLSA Build provenance verifies (`slsa-builder-id`, `slsa-build-type`, `slsa-build-point`), source commit chains to a SLSA Source attestation, builder image chains to a SLSA Build L3 VSA. **This is the VSA wrangle signs and publishes.**

**Tradeoffs:** clean separation of concerns; wrangle PolicySets are reviewable as PRs; the bats harness catches drift; bootstrap stays `slsa-verifier` (transitional); upstream policy bumps are a single SHA edit. Cons: two AMPEL invocations per release; slightly more CI minutes; a `github.com` outage breaks CI (Decision 2 trade-off; see also §10 risk 6).

#### Option B: AMPEL as a Go library linked into a small wrangle CLI

Use `github.com/carabiner-dev/policy` and `github.com/carabiner-dev/ampel/pkg/verifier` directly. Wrangle ships a small `wrangle-verify` binary that compiles policies in and emits a VSA. Preferable only if wrangle wants embedded policies (no remote fetch ever) or wrangle-specific CEL functions. Cost: turns wrangle into a Go project (currently shell + composite actions only) and depends on internal packages clearly evolving (`carabiner-dev/policy/api/v1/`). **Not recommended for the initial rollout.**

#### Option C: Separate verifier service/repo that issues VSAs out-of-band

Closer to Google's BCID model. Formally correct under SLSA L3 (the builder MUST NOT be the verifier of its own provenance — *"for demonstration purposes, the build process is running Tejolote in the same job, which is not ideal (or SLSA 3 compliant)"*, per the SLSA E2E blog). For wrangle's current threat model, Option A is a defensible pragmatic choice; the L3 separation gap is documented in [Appendix A](#appendix-a-docsspecmd-edit)'s SPEC.md edit as a known limitation. **Re-evaluate when wrangle adopters formally require builder/verifier separation, post-v1.0.**

**Recommendation:** Option A for the three-PR rollout. Reopen Option C as a v1.0+ work item.

### 6. Recommended default policy outline

Two PolicySets in `policies/`. Each upstream reference uses the form `git+https://github.com/carabiner-dev/policies@<sha>#<path>` (per Decision 2); the same SHA pin is shared across all three policies in a set so they evaluate against a single upstream snapshot.

#### `wrangle-default-v1`

Subject: the release artifact (sha256 of tarball/wheel/tgz/image). Tenets (AND-mode):

1. **SLSA Build provenance present and valid.** Upstream `slsa/slsa-builder-id.json`, `slsa/slsa-build-type.json`, `slsa/slsa-build-point.json` (the three the Fritoto `gate-publish` set uses). Wrangle context binds the builder identity to `https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_*` (or the language-specific generator) and source repo URI to `github.repository`.
2. **Source commit verifies.** *(Gated on [#174](https://github.com/TomHennen/wrangle/issues/174) — wrangle does not emit a SLSA Source attestation today.)* Upstream `vsa/slsa-source-level3.json` with the chain-to-source-commit CEL pattern from `fritoto-gate-publish.hjson` (see §1 quote). Until #174 lands, this tenet is omitted from `wrangle-default-v1` and the emitted VSA does not claim `SLSA_SOURCE_LEVEL_*`; the rest of the policy ships independently.
3. **SBOM present.** Upstream `sbom/sbom-exists.json` against an SPDX or CycloneDX predicate attached to the artifact.
4. **OSV scan clean modulo VEX.** Upstream `openvex/no-exploitable-vulns-osv.json` with the VEX transformer.
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

A `slsa-verifier verify-vsa` flow is also possible once we confirm it accepts our `verifier.id` (see §2); the consumer doc leads with `cosign verify-blob-attestation` and lists slsa-verifier as a secondary option.

**Layer 2 (for paranoid consumers): re-run the full verification.** Install AMPEL, point at the same release, pass the same policy. (Most adopters won't.)

**Layer 3 (tooling integrators): consume the VSA inside their own admission policy** — the standard SLSA dependency-VSA pattern. The upstream `carabiner-dev/policies` `vsa/` directory already has exemplars.

**Trust chain consumers internalize**: (1) sigstore public-good root; (2) the wrangle workflow OIDC identity (regex on the verify workflow path); (3) the policy SHA-256 in `policy.digest`. Three things, none AMPEL-specific.

### 8. Rollout plan

Three back-to-back PRs, landing over roughly a week. The plan is sequential because PR 2 wires the action PR 1 ships, and PR 3 swaps the install-time helper PR 2 starts using. Each PR is independently reviewable and revertable; none should sit in flight for more than two or three days. An earlier scoping draft split the same work into seven phases stretching across "this quarter" and "next quarter" — none of that sequencing is forced by the technology, and the longer calendar was the only thing it bought.

| PR | What ships | slsa-verifier status |
|----|------------|---------------------|
| **PR 1 — Foundations** | `tools/ampel/install.sh` (mirrors `tools/osv/install.sh`); `actions/verify/action.yml` composite wrapping `carabiner-dev/actions/ampel/verify`; `policies/wrangle-default-v1.hjson` + `policies/wrangle-strict-v1.hjson` (Decision 2); `policies/testdata/` fixtures and bats harness; SARIF in-toto wrapping helper used by zizmor / OSV / Scorecard adapters. | Installed alongside; unchanged. |
| **PR 2 — Publish workflows + consumer docs** | Wire `actions/verify` into Python, npm, and container publish workflows; emit signed VSA on every tagged release as `<artifact>.intoto.jsonl`; document `cosign verify-blob-attestation` flow in `build/actions/{python,npm,container}/README.md`; container path replaces the separate `cosign verify` + `slsa-verifier verify-image` step in `build/actions/container/SPEC.md:153`. | Runs in parallel with AMPEL for one tagged release. If both pass, PR 3 removes it from the publish paths. |
| **PR 3 — Bootstrap swap** | Rewrite `lib/download_verify.sh:84` (`wrangle_verify_provenance`) to call AMPEL with a tool-install policy; OSV/Syft installers pick up the new helper transparently; remove the `slsa-verifier` install step from `actions/scan/action.yml:25-26` and the parallel run from the publish workflows. | Removed from the codebase. |

`slsa-verifier` stays through PR 2 because wrangle's own AMPEL installer relies on it to verify Ampel's provenance bundle; it's removed in PR 3 once AMPEL itself can verify the next AMPEL release. Self-verification through AMPEL's own SLSA provenance would be elegant but adds a moving part exactly where wrangle wants the least magic — the release-blocker installer.

### 9. Key files in wrangle that change

Same three PRs as §8; this is the file-level view.

| File | Change |
|---|---|
| `actions/scan/action.yml:25-26` | PR 1: add `tools/ampel/install.sh` step alongside slsa-verifier install. PR 3: remove slsa-verifier installer. |
| `lib/download_verify.sh:84` (`wrangle_verify_provenance`) | PR 3: rewrite to invoke `ampel verify` with a tool-install policy. |
| `tools/ampel/install.sh` | New in PR 1 — mirrors `tools/osv/install.sh`. |
| `tools/osv/install.sh:69`, `tools/syft/install.sh:112` | PR 3: `osv` currently calls `wrangle_verify_provenance` (SLSA path) and `syft` currently calls `wrangle_download_verify` (checksum path); both follow `lib/download_verify.sh` into AMPEL when that helper is rewritten. |
| `.github/workflows/build_and_publish_python.yml:243-251` | PR 2: replace `slsa-verifier verify-artifact` with AMPEL verify + VSA emit (parallel run with slsa-verifier for one release). |
| `.github/workflows/build_and_publish_npm.yml:241-249` | PR 2: same. |
| `policies/` (new) | PR 1: HJSON PolicySets + `testdata/` fixtures (Decision 2). |
| `actions/verify/action.yml` (new) | PR 1: composite action wrapping `carabiner-dev/actions/ampel/verify`. |
| `build/actions/{python,npm,container}/README.md` | PR 2: document `cosign verify-blob-attestation` consumer flow. |
| `build/actions/container/SPEC.md:153` | PR 2: replace the separate `cosign verify` + `slsa-verifier verify-image` row with a single-VSA flow. |
| `docs/SPEC.md:1046` | This scoping PR: replace the v0.2.0 Ampel bullet with a pointer to this doc and a tracking link. See [Appendix A](#appendix-a-docsspecmd-edit). |

### 10. Risks and open questions

**Risks (ordered by severity):**

1. **AMPEL policy schema instability.** `carabiner-dev/policy` is at v1 but rapidly evolving with one primary maintainer. *Mitigation:* patch-pin AMPEL (Decision: v1.2.1); SHA-pin every upstream `carabiner-dev/policies` reference (Decision 2) so a breaking upstream change cannot reach CI without an explicit SHA bump; fixture-based bats harness in `policies/testdata/`.
2. **Single-vendor governance.** AMPEL is effectively a Carabiner Systems project. OpenSSF donation is planned but unconfirmed. *Mitigation:* consumers depend only on VSA, not on AMPEL — engine substitution stays contained (§2).
3. **CEL expressivity in unfamiliar territory.** Writing CEL that traverses `predicates[0].data.…` with `context.foo` is debuggable but unfamiliar. *Mitigation:* heavy HJSON commenting; `error.guidance` on each tenet; render results as Markdown into `$GITHUB_STEP_SUMMARY`. If Ampel only exposes `--format=html`, the wrapping action converts to a Markdown table before writing the summary.
4. **VSA signing-identity churn.** If the wrangle verify workflow path changes, adopters' `--certificate-identity-regexp` breaks. *Mitigation:* commit to a stable identity regex from day one; treat `verify.yml`'s path as part of the public API; consider a thin wrapper repo for stable identity (the `slsa-framework/source-actions` model) only if it bites.
5. **Repo-rename churn for `verifier.id` and the SARIF predicate type.** Both use `https://github.com/TomHennen/wrangle/...` because no `wrangle.dev`/`wrangle.io` domain is available. If the repo is later renamed or donated (the v1.0 OpenSSF goal), adopters' policies pinning the current URI break. *Mitigation:* treat as a `v1` → `v2` bump event — only break consumers when a previously-passing artifact would now fail. Continue emitting `v1` URIs during a transition window. Grabbing a project-owned domain remains the cleanest long-term fix and is worth a passing attempt before v1.0.
6. **Network dependency on `github.com` at verify time.** Decision 2's locator-based references mean a `github.com` outage breaks a release. *Mitigation:* the runner already requires `github.com` for `actions/checkout` and to push attestations, so the failure surface doesn't expand; if `github.com` is down, the workflow has nothing to attest about anyway. Escape hatch for a future air-gapped requirement: fork an upstream policy into `policies/_lib/` — at which point the Apache-2.0 §4(a)/§4(c) `LICENSE`/`NOTICE` obligation kicks in. Fixture-bats harness doesn't need network (collectors point at local files via `jsonl:`). CEL evaluation itself is fast; the dominant verify-time cost is collector network calls to fetch attestations.
7. **Failure-mode opacity.** If AMPEL can't fetch a referenced attestation, today's CI-readable error story is uneven. *Mitigation:* the Markdown step-summary rendering above (risk 3); the verify action dumps the attestations bundle on failure.
8. **Pin drift across files.** Two distinct pins live in multiple places. (a) The Ampel v1.2.1 pin appears in `tools/ampel/install.sh` (binary + hardcoded SHA-256 fallback), `actions/verify/action.yml` (`carabiner-dev/actions/ampel/verify@<sha>`), and the verifier-identity regex in adopter-facing docs. (b) The `carabiner-dev/policies` SHA pin (Decision 2) appears in every wrangle PolicySet — must stay in lockstep, otherwise different policies in the same evaluation could pull from different upstream snapshots. CLAUDE.md's "Pins drift across files" rule applies to both. *Mitigation:* consolidate each to a single source (a `tools/ampel/VERSION` file for (a); a `policies/UPSTREAM_SHA` file substituted in at evaluation for (b)) or add a regression test that diffs the locations and fails on divergence, following the `make bump-action-pins` precedent. A `make bump-policies` shim that rewrites the SHA across all PolicySet files in one pass is enough if Dependabot can't reach the VCS-locator URI directly.

**Open questions remaining for the implementation issues:**

- **slsa-verifier verify-vsa matching:** does it accept an arbitrary `verifier.id` URL, or require allowlisting? (Read `verifiers.VerifyVSA`.) Affects whether Layer-1 consumer docs offer a slsa-verifier-native command.
- **AMPEL provenance verification:** does `slsa-verifier verify-artifact` accept the sigstore-bundle format AMPEL ships at `ampel-v<ver>.provenance.json`? If not, PR 1 falls back to the hardcoded-SHA pattern.
- **VSA `inputAttestations[].uri` portability:** does the URI survive repo rename or release-asset deletion? (Pull a real Fritoto VSA and check.)

## Recommendations

Land the three PRs from §8 in order. Each is reviewable independently; the whole sequence is roughly a week, not a quarter. This scoping PR's review focus is the four Decisions and the §8 rollout plan.

**Re-evaluate when:**
- AMPEL is donated to OpenSSF, or its schema bumps to v2 — review schema migration, consider Option B library mode.
- An exploit or wide outage in `carabiner-dev/ampel` — invoke the engine-swap option (VSA contract is portable; consumer impact zero).
- SLSA v1.2+ introduces additional VSA fields — bump `wrangle-default-v2`.
- [#174](https://github.com/TomHennen/wrangle/issues/174) lands and wrangle emits a SLSA Source attestation — add the source-commit tenet currently gated out of `wrangle-default-v1` (§6).

**Do not:**
- Require consumers to install AMPEL. The VSA is the only consumer contract (§2).
- Block PR 3 (slsa-verifier removal) on perfection of PRs 1–2. If PR 2 ships a clean release in parallel, PR 3 is safe.
- Delay shipping PR 1 waiting for OpenSSF donation or v2 schema.

## Caveats

- **AMPEL is genuinely young** (§3). The architecture explicitly bets on the engine being swappable (§2); if that bet is broken — e.g., by exposing AMPEL-specific semantics to consumers — the risk profile changes substantially.
- **The OpenSSF donation is a stated plan, not a fait accompli.** Do not let the migration plan depend on it.
- **Some upstream policy file contents and exact CEL strings** (e.g., the body of `carabiner-dev/policies#vsa/slsa-source-level3.json`) were not retrieved verbatim in this research pass. Before authoring `policies/wrangle-default-v1.hjson`, pull the files at the SHA we plan to pin and read them; they document the `context` inputs each one requires and are the source of truth for whatever bindings the wrangle PolicySet must supply.
- **SLSA v1.1 is the current approved spec.** VSA predicate type `https://slsa.dev/verification_summary/v1` is the right target.
- **Option A technically violates SLSA L3 builder/verifier separation**, as the Fritoto blog itself acknowledges for Tejolote-in-same-job. Documented in [Appendix A](#appendix-a-docsspecmd-edit)'s SPEC edit as a known limitation; reopen post-v1.0 (Option C).
- **The sigstore keyless trust chain is the dominant trust assumption.** If an adopter needs an air-gapped path, AMPEL's `--signing-backend=key` works but requires wrangle to publish and rotate a public key.

## Revision history

**Revision 6 — 2026-05-28:** Dedup pass — substance unchanged. TL;DR trimmed to three bullets; §5 publish/signing paragraph reduced to a cross-ref to Decisions 3/4; §6 hoisted the per-tenet `git+https://…@<sha>#…` form to a single sentence at the section top; §8 absorbed the "what this plan deliberately drops" paragraph into its intro; §10 risks 1/6/8 trimmed to point at Decision 2 / §2 / CLAUDE.md instead of restating; Recommendations replaced the parallel four-step list with a one-paragraph pointer to §8; Caveats first bullet cross-refs §2/§3 instead of restating. Revisions 2–5 condensed to one-line summaries — full context lives in the body now.

**Revision 5 — 2026-05-28:** Reversed Decision 2 — dropped vendoring of `carabiner-dev/policies` in favour of SHA-pinned VCS-locator references; cascaded through §5 (no `_lib/`, no Apache-2.0 §4 paragraph), §6 (each tenet refs upstream by `git+https://…@<sha>#path`), §8/§9 (dropped vendored-lib language), §10 risk 6 repurposed as the `github.com` network dependency with the `policies/_lib/` escape hatch, §10 risk 8 extended to cover the new upstream-SHA pin. `make update-policies` replaced by an optional `make bump-policies` shim.

**Revision 4 — 2026-05-28:** §8 collapsed from seven phases to three PRs over a week. §6 source-commit tenet gated on #174. VSA filename switched to the in-toto v1 bundle convention `<artifact>.intoto.jsonl`. §5 spelled out the (then-applicable) Apache-2.0 vendoring obligation. §10 risks 3/7 switched step-summary rendering from HTML to Markdown.

**Revision 3 — 2026-05-28:** §5 considered and rejected `go install` for Ampel; §10 added "Pin drift across files" risk; §10 numbering corrected; inline `*[Revision N …]*` parentheticals stripped.

**Revision 2 — 2026-05-26:** Factual fixes (install action renamed to `install/ampel-bootstrap`; collector-prefix list pruned; `carabiner-dev/actions` v1.2.0 noted; `ampel/verify` action signs by default). Internal contradictions resolved (patch-pin v1.2.1; bats-only test harness; published-action defaults for signing). Structural additions: Decisions block, Appendix A.

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
