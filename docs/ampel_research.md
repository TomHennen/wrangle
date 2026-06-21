# Integrating Ampel into wrangle: Design Analysis and Implementation Plan

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Bootstrap:** keep `slsa-verifier` as wrangle's install-time trust anchor through the final rollout step. | AMPEL ships a sigstore-bundle SLSA provenance (`ampel-v1.2.1.provenance.json`) that `wrangle_verify_provenance` already verifies. A self-verify dance buys nothing. **Superseded (R9):** ampel/bnd are now built from the `tools/go.mod` tool manifest (`go install`); `tools/ampel/install.sh`, its bats, and the `wrangle_verify_gh_attestation` helper are retired. |
| 2 | **Policy distribution:** wrangle authors `wrangle-default-v1` and `wrangle-strict-v1` PolicySets in `policies/`, referencing upstream `carabiner-dev/policies` files by SHA-pinned VCS locator (`git+https://github.com/carabiner-dev/policies@<sha>#slsa/slsa-builder-id.json`) — no vendored copies. Dependabot (or a `make bump-policies` shim if it can't reach the URI) bumps the SHA across all PolicySets atomically. | Mirrors wrangle's SHA-pin discipline; matches the Fritoto reference pattern; avoids the Apache-2.0 `LICENSE`/`NOTICE` redistribution obligation. Trade-off: Ampel resolves the locator on each verify, so the runner needs `github.com` network access (already required for `actions/checkout`). |
| 3 | **VSA signing identity:** sigstore keyless via GitHub OIDC, using `carabiner-dev/actions/ampel/verify` as published — no custom wrapper. | The published action already signs via `bnd statement`, matching `slsa-github-generator`'s identity model. Adopters verify with a stable workflow-path regex. **Superseded (R9):** `actions/verify` invokes `ampel verify` + `bnd` directly — the published wrapper was template-injectable (reported upstream) and its unquoted flag handling broke `--context`. The signer identities are enforced in the PolicySets (`common.identities`), not at the CLI. |
| 4 | **VSA storage:** GitHub release asset is the canonical artifact, named per the in-toto v1 bundle convention (`<artifact>.intoto.jsonl`). Workflow-artifact and `gh attestation` store are best-effort convenience copies. **Amended (R10):** release-asset canonical applies to npm/Go/Python only — containers produce no release, so the container VSA's canonical storage is a **registry OCI referrer** on the image digest (`cosign attach attestation`), retrievable by digest via `cosign download attestation`. **Amended (R12):** the container VSA stays registry-delivered (containers produce no release, so there is no release asset and the verify job requests no `contents: write`); the combined provenance+VSA bundle is the always-available **workflow artifact** file delivery. **Amended (R13):** `cosign attach attestation` accepts only a *single* Sigstore-bundle statement (it rejects a multi-line provenance+VSA concatenation), so the by-digest referrer carries the **VSA statement alone** — provenance is already its own referrer from `attest-build-provenance`, so the digest carries provenance + VSA. A single VSA statement round-trips via `cosign download attestation` with `verificationMaterial` intact, so the VSA referrer push **fails closed** (the by-digest VSA is the path the container consumer verifies — a missing one is a real delivery gap). Unifying every build type onto a single GitHub attestation-store delivery is tracked in [#372](https://github.com/TomHennen/wrangle/issues/372). | Adopters can `wget` the release asset without GitHub auth; the `.intoto.jsonl` name matches the [in-toto attestation bundle spec](https://github.com/in-toto/attestation/blob/main/spec/v1/bundle.md). For containers the image digest is the natural canonical handle, symmetric with the provenance attestation. |

Rollout is three PRs landed back-to-back over roughly a week ([§7](#7-rollout-plan)). All rejected alternatives and the reasons for not taking them live in [§4](#4-paths-not-taken). The `docs/SPEC.md` pointer edit is in [Appendix A](#appendix-a-docsspecmd-edit).

## TL;DR

- **AMPEL inside wrangle, VSA at the boundary.** Consumers trust only the signed SLSA Verification Summary Attestation (`predicateType: https://slsa.dev/verification_summary/v1`). Two validated complete-check options: (a) **`ampel verify` against a wrangle-hosted consumer PolicySet** (`policies/wrangle-vsa-consumer-v1.hjson`), one command — recommended, needs ampel; (b) **`cosign verify-blob-attestation --new-bundle-format` + a `jq` predicate check** — no ampel. AMPEL downstream is an accepted *option*, not lock-in; the cosign path keeps a no-ampel route. `slsa-verifier verify-vsa` does **not** work (keyless VSAs; see §8 R11).
- **AMPEL is the right engine for the multi-attestation job slsa-verifier cannot do**, despite being young — v1.2.1, ~49 stars, primarily one maintainer ([§3](#3-ampel-maturity-is-the-dominant-risk)). It natively emits VSAs and ships a working e2e demo. Other engines were considered ([§4](#4-paths-not-taken)).
- **Ship in three back-to-back PRs over roughly a week, not a multi-quarter migration** ([§7](#7-rollout-plan)).

## Key Findings

### 1. AMPEL is concretely capable of replacing wrangle's verify story

AMPEL ("The Amazing Multi-Purpose Policy Engine (and L)"), at `github.com/carabiner-dev/ampel`, is a Go binary plus library that:

- Consumes in-toto Statements (signed sigstore bundles or DSSE envelopes) and evaluates **policies-as-code** in JSON/HJSON with executable tenets in **CEL** (`runtime: "cel@v0"`). Cedar, Rego, and JavaScript runtimes are on the roadmap but not shipping.
- Has a first-class **`PolicySet`** — a remote-referenceable, hash-pinnable bundle (`git+https://github.com/org/repo#path/policy.json`), linkable to OSCAL controls.
- Loads attestations from pluggable **collector drivers** — the list isn't exhaustively documented but at least `coci:`, `oci:`, `github:`, `jsonl:`, `fs:`, `note:`, `dnote:`, `release:`, and `http(s):` are referenced in the demo, action, and source.
- Emits results in three formats via `--attest-format`: `ampel` (default; `https://carabiner.dev/ampel/resultset/v0`), **`vsa` (`https://slsa.dev/verification_summary/v1`)**, or `svr` (`https://in-toto.io/attestation/svr/v0.1`). VSA field shape is detailed in §2.
- Signs results via the bundled `bnd statement` tool (sigstore-keyless via OIDC in GitHub Actions, key-based otherwise). The published action signs by default when an OIDC token is available — no `--sign` flag required.
- Supports **subject chaining**: a CEL selector pivots from one in-toto subject (e.g., a binary) to another (e.g., the source commit named in its provenance) and re-fetches attestations for the chained subject. From `fritoto-gate-publish.hjson`:

  ```
  predicates[0].data.buildDefinition.resolvedDependencies.map(
      dep, dep.uri.startsWith(context.buildPointRepo + '@'), dep)[0]
  ```

  This is the only practical way to write a single policy that simultaneously gates "binary built from SLSA Source L3 commit by a SLSA Build L3 builder with a clean OSV scan and an SBOM."
- **Transformers** are Go-compiled adapters (e.g., VEX, vuln-scanner-to-OSV) loaded on demand so one rule covers Grype/Trivy/OSV uniformly. Upstream flags the framework as "still under development."
- Has a published GitHub Action at `carabiner-dev/actions/ampel/verify` and an installer action `carabiner-dev/actions/install/ampel-bootstrap` (the latter uses hardcoded SHA-256 hashes as trust root). Latest `carabiner-dev/actions` tag is v1.2.0 (2026-05-06).

The canonical reference is `carabiner-dev/demo-slsa-e2e` ("Fritoto"), walked through in the SLSA-foundation blog post *"SLSA End-to-End With AMPEL & Friends"* (2025-10-21). It performs exactly the workflow wrangle wants: verify source commit and builder image; gate on SBOM + OSV + VEX + tests; build; generate SLSA provenance with Tejolote; re-verify and emit per-binary VSAs; attach to the release. §5 mirrors Fritoto's two-stage gate structure directly.

### 2. The VSA contract is portable; the AMPEL policy is not

The output VSA conforms to SLSA v1.0/v1.1 `https://slsa.dev/verification_summary/v1`. The published Fritoto sample shows the full field set: `verifier.id`, `timeVerified`, `resourceUri`, `policy.digest` (sha256+sha512), `verificationResult` (`PASSED`/`FAILED`), `verifiedLevels` (e.g., `SLSA_BUILD_LEVEL_3`), `dependencyLevels`, `slsaVersion: 1.1`, and `inputAttestations[]` with digests and URIs.

This is exactly what `slsa-verifier verify-vsa` consumes. Google publishes VSAs for GKE Container-Optimized OS images via the same flow (`cli/slsa-verifier/testdata/vsa/gce/v1/gke-gce-pre.bcid-vsa.jsonl`).

Nothing in the consumer-side verification path requires AMPEL as the *only* option: a no-AMPEL path verifies with `cosign verify-blob-attestation --bundle <artifact>.intoto.jsonl --new-bundle-format …` plus a `jq` predicate-field check (cosign does not inspect predicate fields). `slsa-verifier verify-vsa` is **not** an option — it requires `--public-key-path` and verifies only key-signed VSAs, while wrangle's are keyless (see §8, R11). The AMPEL-specific bits (HJSON+CEL, transformers, `predicates[].data…` runtime, `context.foo` interpolation) are *internal* to wrangle. This is the architectural split the rollout bets on — keep it intact and the engine stays swappable; expose AMPEL-specific semantics to consumers and the bet breaks, which matters given AMPEL's youth (§3).

### 3. AMPEL maturity is the dominant risk

- **Project age**: first commit January 2025; v1.2.1 released 2026-04-22; roughly monthly cadence. `slsa-verifier` has been the canonical SLSA Build verifier in continuous use since June 2022.
- **Stars / community**: 49 stars, 13 forks, primarily one maintainer (@puerco, Carabiner Systems). The OSPS Baseline community-policy set is contributed to `carabiner-dev/policies`. OpenSSF donation is *planned* per the *"From Mild to Wild"* session at Open Source SecurityCon Europe 2026 (recapped by TLDRecap.tech), but no sandbox/incubating entry exists yet.
- **Governance**: a `GOVERNANCE.md` exists; the project is effectively single-vendor (Carabiner Systems, Apache-2.0).
- **Spec stability**: result-attestation predicate URIs include `v0` (`https://carabiner.dev/ampel/resultset/v0`); the policy schema (`carabiner-dev/policy`, protobuf-generated) is still evolving. Wrangle patch-pins AMPEL (v1.2.1) — see §8 risk 1.

### 4. Paths not taken

This section is the canonical home for everything wrangle considered and rejected. Other sections state the picked path and link back here.

**Alternative policy engines.**

- **Conforma** (formerly Enterprise Contract, conforma.dev): Rego/OPA-based, container-image-centric, Konflux/Tekton-shaped. Older than AMPEL, with a real policy library and Quay-published bundles. Does NOT natively emit VSAs — the OSSEU 2026 *"From Mild to Wild"* demo shimmed one over `ec validate image` JSON. For wrangle's GitHub-Actions flow combining SLSA provenance + SBOM + OSV + zizmor + Scorecard into one signed VSA, more rework than AMPEL.
- **Hand-roll in wrangle**: tempting because each policy is small, but you give up `carabiner-dev/policies`, transformers, OSCAL linking, and free signing — and become the maintainer of yet another policy DSL.
- **OPA/Rego direct, in-toto-verifier with layouts, sigstore policy-controller**: all admission-controller-shaped, don't emit VSAs by themselves. Macaron (Oracle) does emit VSAs but is tied to its own predicate types.

AMPEL is the only tool today that natively emits a SLSA-standard VSA, understands sigstore-bundle attestations, ships a GitHub Action, and has a working e2e demo to crib from.

**Alternative integration architectures.** §5 picks Option A.

- **Option B — AMPEL as a Go library.** Wrangle ships a small `wrangle-verify` binary linking `carabiner-dev/policy` + `carabiner-dev/ampel/pkg/verifier` directly. Preferable only with embedded policies (no remote fetch) or wrangle-specific CEL. Cost: turns wrangle into a Go project (currently shell only) and depends on clearly-evolving internal packages.
- **Option C — Separate verifier service/repo issuing VSAs out-of-band.** Closer to Google's BCID model and formally correct under SLSA L3 (the builder MUST NOT be the verifier of its own provenance — *"for demonstration purposes, the build process is running Tejolote in the same job, which is not ideal (or SLSA 3 compliant)"*, per the SLSA E2E blog). Option A is a defensible pragmatic choice for wrangle's current threat model; the L3 gap is documented in [Appendix A](#appendix-a-docsspecmd-edit). Reopen post-v1.0 when adopters require builder/verifier separation.

**Install method for Ampel.** **Superseded (R9): ampel/bnd are now built from `tools/go.mod` via `go install`** — for a Go tool fetched from its canonical module path this is not a meaningful downgrade (a source-repo compromise defeats build-provenance equally, and the module path pins the origin), and `go.mod` adds Dependabot coverage of the tools' transitive CVE surface. The original reasoning below is kept for the record. §5 picks binary + SLSA-provenance (mirroring `tools/osv/install.sh`). `go install github.com/carabiner-dev/ampel/cmd/ampel@v1.2.1` was rejected under CLAUDE.md's integrity-tier rule: AMPEL's sigstore-bundle SLSA provenance is top-tier; `go install` via sum.golang.org is hash-pinned-PM tier (per CLAUDE.md, "the sumdb attests immutability of the first-seen `(module, version)`, NOT publisher authenticity"). Adopting `go install` would *downgrade* verification, which the "NEVER fall back to a weaker tier" rule disallows.

**VSA self-verification from PR 1.** Elegant but adds a moving part exactly where wrangle wants the least magic — the release-blocker installer. §7 keeps `slsa-verifier` through PR 2 and removes it in PR 3.

**Wrapper repo for stable signing identity** (the `slsa-framework/source-actions` model, hedging against future `verify.yml` renames). Deferred — adopt only if identity churn actually bites; the workflow path is treated as part of the public API in the meantime. Cross-ref: §8 risk 4.

## Details

### 5. Recommended integration architecture (Option A)

AMPEL CLI invoked from wrangle's publish workflows; policies in-repo. Alternatives B and C live in §4.

**Where things live:**

> **Superseded (R9):** the install/verify specifics in this section reflect the original plan. As shipped, ampel/bnd build from `tools/go.mod` via `go install` (there is no `tools/ampel/install.sh`), and `actions/verify` invokes `ampel verify` + `bnd` directly rather than wrapping `carabiner-dev/actions/ampel/verify`.

- **`tools/ampel/install.sh`** — new installer mirroring `tools/osv/install.sh` (download binary, fetch provenance, call `wrangle_verify_provenance`). AMPEL ships `ampel-v<ver>.provenance.json` as a sigstore-bundle SLSA provenance; if `slsa-verifier verify-artifact` doesn't accept it, fall back *statically* to the hardcoded SHA-256 pattern used by `carabiner-dev/actions/install/ampel-bootstrap` (CLAUDE.md's no-runtime-fallback rule). (`go install` rejected — §4.)
- **`policies/`** — new top-level directory holding wrangle-authored PolicySets (per Decision 2):
  - `policies/wrangle-default-v1.hjson` and `policies/wrangle-strict-v1.hjson` (land in PR 1) — composed from upstream `carabiner-dev/policies` files; each PolicySet's `context` block supplies wrangle-specific bindings (builder ID regex, repo URI, expected predicate types) to the otherwise-generic upstream policies.
  - `policies/python-build-l3.hjson` and `policies/npm-build-l3.hjson` — per-ecosystem bindings consumed by the publish workflows.
  - If a future change forks an upstream policy (e.g., a CEL clause upstream rejects), the fork moves into `policies/_lib/` and the Apache-2.0 §4(a)/§4(c) obligation kicks in then — see §8 risk 6.
- **`policies/testdata/`** — fixture attestation bundles (`good-*.jsonl`, `bad-*-missing-sbom.jsonl`, etc.) plus golden VSAs. A bats target runs `ampel verify` against fixtures and asserts result + `verifiedLevels`. **The single most important PR 1 deliverable** — HJSON+CEL+context drift is silent otherwise.
- **`actions/verify/action.yml`** — composite action taking `subject`, `policy`, `collector`; calls `carabiner-dev/actions/ampel/verify@<sha>` with `--attest-format=vsa --push-attestation=true`. Uploads the VSA as a workflow artifact and (on tagged releases) attaches it to the GitHub release.
- **Scanner outputs** continue to come out of `actions/scan` as today; each scanner's adapter is augmented to wrap its SARIF in an in-toto Statement (via `bnd predicate`/`bnd statement`) and append to `.attestations/attestations.bundle.jsonl`. SARIF is **not** in the `in-toto/attestation` vetted predicate list (as of 2026-05), so **wrangle defines `https://github.com/TomHennen/wrangle/attestation/sarif/v0.1`** and uses it for the zizmor / OSV / Scorecard wrapping (same namespace as the `verifier.id` in §6). Upstreaming is a v1.0 work item.

**Signing and publishing:** see Decisions 3 and 4. The verifier identity is the wrangle release workflow's Fulcio cert (`https://github.com/TomHennen/wrangle/.github/workflows/verify.yml@refs/tags/v.+`) — public API; see §8 risk 4 for stability commitments. The composite action renames Ampel's default `ampel.intoto.json` to `<artifact>.intoto.jsonl` on publish.

**Policy evaluation runs in two stages**, mirroring Fritoto (§1):

1. **Pre-build gate** (`fritoto-gate-build`-shaped): SBOM exists, OSV scan clean modulo VEX, tests pass, zizmor clean, source commit attestations verify. Runs before the build step; result blocks the workflow but isn't released.
2. **Pre-publish gate** (`fritoto-gate-publish`-shaped, 5 policies in the demo): SLSA Build provenance verifies (`slsa-builder-id`, `slsa-build-type`, `slsa-build-point`); source commit chains to a SLSA Source attestation; builder image chains to a SLSA Build L3 VSA. **This is the VSA wrangle signs and publishes.**

**Tradeoffs:** PolicySets are reviewable as PRs; the bats harness catches drift; upstream policy bumps are a single SHA edit; bootstrap stays `slsa-verifier` (transitional). Cons: two AMPEL invocations per release (slightly more CI minutes); `github.com` is a verify-time dependency — see §8 risk 6.

### 6. Recommended default policy outline

> **Superseded (#316/#328):** the generic `wrangle-default-v1` / `wrangle-strict-v1` outlined below were retired once `attest-build-provenance` made `builder.id` per-ecosystem; the shipped tiers are the per-eco `wrangle-{default,strict}-<eco>-v1`.

Two PolicySets in `policies/`. Each upstream reference uses `git+https://github.com/carabiner-dev/policies@<sha>#<path>` (Decision 2); one SHA pin per set so all tenets evaluate against the same upstream snapshot.

#### `wrangle-default-v1`

Subject: the release artifact (sha256 of tarball/wheel/tgz/image). Tenets (AND-mode):

1. **SLSA Build provenance present and valid.** Upstream `slsa/slsa-builder-id.json`, `slsa/slsa-build-type.json`, `slsa/slsa-build-point.json` (the three Fritoto `gate-publish` uses). Wrangle context binds the builder identity to `https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_*` (superseded by #316 — now `https://github.com/TomHennen/wrangle/.github/workflows/build_and_publish_<eco>.yml`) and source repo URI to `github.repository`.
2. **Source commit verifies.** *(Gated on [#174](https://github.com/TomHennen/wrangle/issues/174) — wrangle doesn't emit a SLSA Source attestation today.)* Upstream `vsa/slsa-source-level3.json` with the chain-to-source-commit CEL from `fritoto-gate-publish.hjson` (§1 quote). Until #174 lands, omitted from `wrangle-default-v1` and the VSA doesn't claim `SLSA_SOURCE_LEVEL_*`; the rest ships independently.
3. **SBOM present.** Upstream `sbom/sbom-exists.json` against an SPDX or CycloneDX predicate on the artifact.
4. **OSV scan clean modulo VEX.** Upstream `openvex/no-exploitable-vulns-osv.json` with the VEX transformer.
5. **zizmor SARIF clean.** Wrangle-authored, under the wrangle SARIF predicate type (§5) — lives in `policies/` (no upstream equivalent yet).
6. **Sigstore signature on the artifact.** Wrangle workflow OIDC identity expected as signer. Wrangle-authored.

Emits VSA with `verifiedLevels: ["SLSA_BUILD_LEVEL_3"]` (assuming valid build provenance; superseded by #316 — now from `actions/attest-build-provenance`, not slsa-github-generator), `verifier.id: https://github.com/TomHennen/wrangle/verifier/v1`, `resourceUri` set to the artifact's purl, and `policy.uri`/`policy.digest` recording the wrangle policy reference and content digest.

#### `wrangle-strict-v1`

Additive over default: Scorecard ≥ 7; no HIGH/CRITICAL OSV findings even with VEX; declared tool dependencies (Syft, OSV-Scanner, AMPEL) themselves have valid VSAs at SLSA_BUILD_LEVEL_3 (chained subjects); reproducible/hermetic build attestation where the language ecosystem supports it.

`wrangle-strict-v1` is the policy wrangle itself dogfoods on its own releases.

### 7. Rollout plan

Three back-to-back PRs, landing over roughly a week. The plan is sequential because PR 2 wires the action PR 1 ships, and PR 3 swaps the install-time helper PR 2 starts using. Each PR is independently reviewable and revertable; none should sit in flight for more than two or three days.

> **Superseded (R9):** PR 1's mechanics changed — it ships `tools/go.mod` (not `tools/ampel/install.sh`) and a direct-invoke `actions/verify` (not a wrapper around `carabiner-dev/actions/ampel/verify`). The three-phase structure below is otherwise as planned.

| PR | What ships | slsa-verifier status |
|----|------------|---------------------|
| **PR 1 — Foundations** | `tools/ampel/install.sh`; `actions/verify/action.yml` wrapping `carabiner-dev/actions/ampel/verify`; `wrangle-default-v1`/`wrangle-strict-v1` PolicySets in `policies/` (Decision 2); `policies/testdata/` fixtures + bats harness; SARIF in-toto wrapping helper for zizmor / OSV / Scorecard. | Installed alongside; unchanged. |
| **PR 2 — Publish workflows + consumer docs** | Wire `actions/verify` into Python, npm, container publish workflows; emit signed `<artifact>.intoto.jsonl` on every tagged release; document the `cosign verify-blob-attestation` flow (file-by-file changes in the table below). | Runs in parallel for one tagged release; if both pass, PR 3 removes it. |
| **PR 3 — Bootstrap swap** | Rewrite `lib/download_verify.sh:84` (`wrangle_verify_provenance`) to call `ampel verify` with a tool-install policy; OSV/Syft installers pick up the new helper transparently; remove the `slsa-verifier` install step from `actions/scan/action.yml:25-26` and the parallel publish-workflow run. | Removed from the codebase. |

`slsa-verifier` stays through PR 2 because wrangle's AMPEL installer uses it to verify Ampel's provenance bundle; it's removed in PR 3 once AMPEL can verify the next AMPEL release. (Self-verification from PR 1: §4.)

#### File-level view

| File | Change |
|---|---|
| `actions/scan/action.yml:25-26` | PR 1: add `tools/ampel/install.sh` step alongside slsa-verifier install. PR 3: remove slsa-verifier installer. |
| `lib/download_verify.sh:84` (`wrangle_verify_provenance`) | PR 3: rewrite to invoke `ampel verify` with a tool-install policy. |
| `tools/ampel/install.sh` | New in PR 1 — mirrors `tools/osv/install.sh`. |
| `tools/osv/install.sh:69`, `tools/syft/install.sh:112` | PR 3: both pick up the rewritten `lib/download_verify.sh` helpers transparently (osv via `wrangle_verify_provenance`, syft via `wrangle_download_verify`). |
| `.github/workflows/build_and_publish_python.yml:243-251` | PR 2: replace `slsa-verifier verify-artifact` with AMPEL verify + VSA emit (parallel run with slsa-verifier for one release). |
| `.github/workflows/build_and_publish_npm.yml:241-249` | PR 2: same. |
| `policies/` (new) | PR 1: HJSON PolicySets + `testdata/` fixtures (Decision 2). |
| `actions/verify/action.yml` (new) | PR 1: composite action wrapping `carabiner-dev/actions/ampel/verify`. |
| `build/actions/{python,npm,container}/README.md` | PR 2: document `cosign verify-blob-attestation` consumer flow. |
| `build/actions/container/SPEC.md:153` | PR 2: replace the separate `cosign verify` + `slsa-verifier verify-image` row with a single-VSA flow. |
| `docs/SPEC.md:1046` | This scoping PR: replace the v0.2.0 Ampel bullet with a pointer to this doc and a tracking link. See [Appendix A](#appendix-a-docsspecmd-edit). |

### 8. Risks and open questions

**Risks (ordered by severity):**

1. **AMPEL policy schema instability.** `carabiner-dev/policy` is at v1 but rapidly evolving with one primary maintainer. *Mitigation:* patch-pin AMPEL (Decision: v1.2.1); SHA-pin every upstream reference (Decision 2) so a breaking upstream change cannot reach CI without an explicit SHA bump; fixture-based bats harness in `policies/testdata/`.
2. **Single-vendor governance.** AMPEL is effectively a Carabiner Systems project. OpenSSF donation is planned but unconfirmed. *Mitigation:* consumers depend only on VSA, not on AMPEL — engine substitution stays contained (§2).
3. **CEL expressivity in unfamiliar territory.** Writing CEL that traverses `predicates[0].data.…` with `context.foo` is debuggable but unfamiliar. *Mitigation:* heavy HJSON commenting; `error.guidance` on each tenet; render results as Markdown into `$GITHUB_STEP_SUMMARY` (converting from `--format=html` if that's all Ampel exposes).
4. **VSA signing-identity churn.** If the wrangle verify workflow path changes, adopters' `--certificate-identity-regexp` breaks. *Mitigation:* commit to a stable identity regex from day one; treat `verify.yml`'s path as part of the public API. (A thin wrapper repo as an extra hedge was considered — see §4.)
5. **Repo-rename churn for `verifier.id` and the SARIF predicate type.** Both URIs use `https://github.com/TomHennen/wrangle/...` (no `wrangle.dev` domain available); a repo rename or OpenSSF donation breaks adopters' pinned policies. *Mitigation:* treat as a `v1` → `v2` bump — only break consumers when a previously-passing artifact would now fail; emit `v1` URIs during a transition window. Grabbing a project-owned domain before v1.0 is the cleanest long-term fix.
6. **Network dependency on `github.com` at verify time.** Decision 2's locator-based references mean a `github.com` outage breaks a release. *Mitigation:* the runner already requires `github.com` for `actions/checkout` and attestation push — failure surface doesn't expand, and a down `github.com` leaves the workflow nothing to attest about. Air-gap escape hatch: fork upstream policies into `policies/_lib/` (Apache-2.0 §4(a)/§4(c) `LICENSE`/`NOTICE` obligation kicks in then). The bats harness uses local-file collectors (`jsonl:`) and doesn't need network.
7. **Failure-mode opacity.** If AMPEL can't fetch a referenced attestation, today's CI-readable error story is uneven. *Mitigation:* the Markdown step-summary rendering above (risk 3); the verify action dumps the attestations bundle on failure.
8. **Pin drift across files.** Pins must stay in lockstep, falling under CLAUDE.md's "Pins drift across files" rule. **(a) Superseded (R9):** the original ampel-version pin set (install.sh binary + the upstream-wrapper action + the adopter-doc regex) collapsed — ampel/bnd versions are now single-sourced in `tools/go.mod` and Dependabot-bumped. **(b)** the `carabiner-dev/policies` SHA (Decision 2) must stay identical across every wrangle PolicySet, otherwise a single evaluation could mix snapshots. *Mitigation:* single-source files (`tools/ampel/VERSION` for (a); `policies/UPSTREAM_SHA` substituted at evaluation for (b)) or a divergence-fail regression test, following the `make bump-action-pins` precedent. A `make bump-policies` shim covers (b) if Dependabot can't reach the VCS-locator URI.

**Open questions remaining for the implementation issues:**

- **`slsa-verifier verify-vsa` matching:** **resolved (R11) — not usable.** `verify-vsa` requires `--public-key-path` and verifies only *key-signed* VSAs; wrangle's are keyless (Fulcio/Sigstore), with no identity flag to pass. So it is dropped as a consumer option entirely (the `verifier.id` question below is moot for our path). The validated consumer paths are `ampel verify` (against the wrangle-hosted consumer PolicySet) and `cosign verify-blob-attestation` + `jq`.
- **AMPEL provenance verification:** does `slsa-verifier verify-artifact` accept the sigstore-bundle format AMPEL ships at `ampel-v<ver>.provenance.json`? If not, PR 1 falls back to the hardcoded-SHA pattern.
- **VSA `inputAttestations[].uri` portability:** does the URI survive repo rename or release-asset deletion? (Pull a real Fritoto VSA and check.)
- **Upstream policy bodies not yet retrieved verbatim:** `carabiner-dev/policies#vsa/slsa-source-level3.json` and its siblings weren't pulled in this pass. Before authoring `policies/wrangle-default-v1.hjson`, fetch them at the SHA to pin — they document the `context` inputs each one requires.
- **Air-gapped signing:** the sigstore-keyless trust chain is the dominant trust assumption. An air-gapped path needs AMPEL's `--signing-backend=key`, which requires wrangle to publish and rotate a public key. Out of scope until an adopter needs it.

### 9. Downstream consumer UX

Three layers, documented in `build/actions/{python,npm,container}/README.md`:

**Layer 1 (no-ampel path): `cosign verify-blob-attestation` + `jq`.** The VSA is keyless-signed by *wrangle's* reusable workflow (`build_and_publish_<type>.yml`), so the cert identity is wrangle's path; `--certificate-github-workflow-repository` pins the build to the consumer's repo.

```bash
gh release download v1.2.3 --repo my-org/my-app -p '*.intoto.jsonl' -p 'my-app-*.tgz'
cosign verify-blob-attestation \
  --bundle my-app-1.2.3.tgz.intoto.jsonl \
  --new-bundle-format \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_npm\.yml@refs/tags/v' \
  --certificate-github-workflow-repository my-org/my-app \
  --type https://slsa.dev/verification_summary/v1 \
  my-app-1.2.3.tgz
```

cosign does not inspect predicate fields, so the consumer doc pairs this with a `jq` check of `verificationResult` / `resourceUri` / `verifiedLevels`. `slsa-verifier verify-vsa` is **not** offered — it verifies only key-signed VSAs (§8 R11).

**Layer 2 (one-command complete check): `ampel verify` against the wrangle-hosted consumer PolicySet.** `policies/wrangle-vsa-consumer-v1.hjson`, fetched by VCS locator — the consumer authors nothing, but installs ampel. Recommended where ampel is available (and the only digest-native path for containers, whose VSA subject is the image digest). AMPEL downstream is an accepted option, not lock-in; Layer 1 remains the no-ampel route.

**Layer 3 (tooling integrators): consume the VSA inside their own admission policy** — the standard SLSA dependency-VSA pattern. The upstream `carabiner-dev/policies` `vsa/` directory already has exemplars.

**Trust chain consumers internalize**: (1) sigstore public-good root; (2) the wrangle workflow OIDC identity (regex on the `build_and_publish_<type>.yml` reusable-workflow path that signs the VSA); (3) the policy SHA-256 in `policy.digest`. Three things, none AMPEL-specific (per §2).

## Recommendations

Land the three PRs from §7 in order. Review focus for this scoping PR: the four Decisions and the §7 rollout plan.

**Re-evaluate when:**
- AMPEL is donated to OpenSSF or its schema bumps to v2 — review migration; consider Option B (§4).
- An exploit or wide outage in `carabiner-dev/ampel` — invoke engine swap (VSA is portable; zero consumer impact).
- SLSA v1.2+ adds VSA fields — bump `wrangle-default-v2`.
- [#174](https://github.com/TomHennen/wrangle/issues/174) lands — add the source-commit tenet currently gated out of `wrangle-default-v1` (§6).

The migration must not depend on the OpenSSF donation landing (§3), and PR 1 must not wait on it. Consumers never install AMPEL — the VSA is the only consumer contract (§2).

## Revision history

**Revision 13 — 2026-06-15:** Container by-digest VSA referrer restored, fail-closed (#444/#447). `cosign attach attestation` accepts only a single Sigstore-bundle statement — a multi-line provenance+VSA concatenation is rejected — so the by-digest referrer pushes the **VSA statement alone** (one image subject → one VSA), which round-trips through `cosign download attestation` with `verificationMaterial` intact; provenance is already its own referrer from `attest-build-provenance`. Because that by-digest VSA referrer is the path the container consumer (`verify-container-vsa`, `cosign verify-attestation --type …/verification_summary/v1`) verifies, the push **fails closed** (through the shared transient-Sigstore retry) rather than the R12 best-effort log-and-continue — a missing by-digest VSA is a real delivery gap. The combined provenance+VSA bundle remains the workflow-artifact file delivery.

**Revision 12 — 2026-06-12:** Container VSA delivery — file bundles + registry referrer (#444). Containers produce no GitHub release, so the verify job requests no `contents: write`; the combined provenance+VSA bundle is delivered as the workflow artifact, and the VSA is pushed back to the registry as an OCI referrer on the image digest. (R13 refines the referrer to the VSA statement alone and makes it fail-closed.)

**Revision 11 — 2026-06-03:** Consumer-verification correction (#310). Empirical validation against the real VSAs reversed R10's "lead with `slsa-verifier verify-vsa`" claim: `slsa-verifier verify-vsa` (v2.7.1) requires `--public-key-path` and verifies only *key-signed* VSAs, while wrangle's are **keyless** (Fulcio/Sigstore) — there is no identity flag, so the tool is **dropped as a consumer option** (and the R10 `--verifier-id` advice is moot). The two validated complete-check paths are now: (a) **`ampel verify`** against the wrangle-hosted consumer PolicySet `policies/wrangle-vsa-consumer-v1.hjson` (one command; recommended; needs ampel; the only digest-native path for containers), and (b) **`cosign verify-blob-attestation` + a `jq` predicate-field check** (no ampel — cosign checks signature/signer-identity/subject-hash but not predicate fields). For cosign's `--type`, the full URI `https://slsa.dev/verification_summary/v1` is required; the `slsaverificationsummary` alias is rejected by cosign v3. AMPEL downstream is an accepted option, not lock-in. The README/`docs/SPEC.md` consumer sections were rewritten to match.

**Revision 10 — 2026-06-02:** Container VSA registry storage + ampel `verifier.id` correction (#310). *Decision 4 amended:* the release-asset-canonical rule holds for npm/Go/Python; the container VSA's canonical storage is a registry OCI referrer pushed with `cosign attach attestation` (uploads the bnd-signed bundle verbatim — no re-sign), retrievable by digest via `cosign download attestation`. *§6/§8 correction:* ampel v1.2.1 **hardcodes** the VSA `verifier.id = https://carabiner.dev/ampel@v1` (`internal/drivers/vsa/driver.go`), not the `https://github.com/TomHennen/wrangle/verifier/v1` URL §6 assumed; consumers running `slsa-verifier verify-vsa` therefore pass `--verifier-id https://carabiner.dev/ampel@v1`. This resolves the §8 open question ("does `verify-vsa` accept an arbitrary `verifier.id`?") in the affirmative — the consumer docs now lead with `slsa-verifier verify-vsa` and keep `cosign verify-blob-attestation` as the signer-identity alternate. Note: `cosign attach attestation` in the installed cosign (cosign v3.0.6, via cosign-installer v4.1.2) takes `--attestation <file> <image-ref>` and has **no** `--new-bundle-format` flag — the push arg vector omits it.

**Revision 9 — 2026-05-31:** Implementation pivots during the Foundations build (#283). *Decision 1 reversed:* ampel/bnd are built from a `tools/go.mod` tool manifest (`go install`), retiring `tools/ampel/install.sh`, its bats, and the `wrangle_verify_gh_attestation` helper. For a Go tool fetched from its canonical module path, `go install` (build-from-source + `go.sum`/`sum.golang.org`) is not a meaningful downgrade from binary + build-provenance — a source-repo compromise defeats build-provenance equally, and the module path pins the origin — while `go.mod` brings Dependabot coverage of the tools' transitive CVE surface (which surfaced the go-git/gitsign/x-crypto advisories). *Decision 3 reversed:* `actions/verify` invokes `ampel verify` + `bnd` directly rather than wrapping `carabiner-dev/actions/ampel/verify`, which was template-injectable (reported upstream) and whose unquoted flag handling broke `--context`. *New — signer-identity binding:* each attestation maps to a signing identity. The PolicySets require the SLSA provenance to be signed by the `slsa-github-generator` keyless identity (`common.identities`, fail-closed — no `--signer` flag to forget); SBOM/OSV/Scorecard bindings stay gated until wrangle signs those. `policies/test.bats` derives a logic-only variant (identity gate stripped) for the tenet tests and adds a dedicated fail-closed enforcement test.

**Revision 8 — 2026-05-29:** Second dedup pass (round-5 review). Removed the Caveats section — its swappability/youth points duplicated §2/§3, and its two unique items (unretrieved upstream policy bodies, air-gapped signing) moved to §8 open questions. Dropped the Recommendations "Do not" list — each point was already stated in §2/§7, now a single trailing line. Condensed the revision history.

**Revision 7 — 2026-05-28:** Names removed (talks cited by title/venue, maintainer by `@puerco`). First aggressive dedup: §4 made the canonical "Paths not taken" home; §5/§7 cross-reference it instead of restating; §2 absorbed the `verifier.id` open question.

**Revisions 1–6 — 2026-05-26..28:** Initial cloud-agent research pass, then iterative review fixes — Decisions block + Appendix A added (R2); `go install` rejected and pin-drift risk added (R3); seven phases collapsed to three PRs, source-commit tenet gated on #174, VSA filename → `<artifact>.intoto.jsonl`, step summary → Markdown (R4); Decision 2 reversed from vendoring to SHA-pinned VCS locators (R5); first dedup pass (R6).

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
