# SLSA Build Track requirements mapping

Wrangle's goal is to **prove that a single reusable-workflow call can produce a
verifiable SLSA Build L3 artifact** — without the adopter wiring up provenance,
signing, or verification themselves. This document is the maintained claim
behind that goal: each [SLSA v1.2 Build Track](https://slsa.dev/spec/v1.2/build-requirements)
requirement, broken down to its individual MUST/SHOULD sub-points, with a
verdict and `file:line` evidence you can re-verify. It follows the SLSA project's
own [`source-tool` requirements mapping](https://github.com/slsa-framework/source-tool/blob/main/docs/REQUIREMENTS_MAPPING.md)
for the Source Track.

It is the **source of truth for the level wrangle claims.**
[`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md) is the point-in-time isolation review that
drove the hardening — read it for the *why*, this page for the *what*. Verdicts:
**MEETS** / **PARTIAL** / **GAP** / **N/A**. Requirement text is paraphrased from
SLSA v1.2 `build-requirements.md` and `build-provenance.md` at the `v1.2` tag;
follow the links for exact wording.

## Scope and preconditions

Every verdict holds **only** under these conditions — they are part of the
claim, not footnotes:

- **Reusable-workflow consumption only.** Verdicts apply when an adopter calls
  `TomHennen/wrangle/.github/workflows/build_and_publish_<type>.yml`. Calling the
  composite actions under `build/actions/<type>/` directly is **not** an L3 path
  (see *Unforgeable* → direct-composite gap).
- **GitHub-hosted runners only.** Self-hosted runners void the Isolated, Hosted,
  and ephemeral-environment verdicts; the precondition is restated on each.
- **The build platform is trusted and isolated regardless of operator.** The
  analysis treats wrangle's reusable workflow as the isolated build platform; it
  does not assume the operator is a third party distinct from the source owner.
  An org running its **own fork** is in scope (the canonical SLSA "operate your
  own builder" posture) — see the self-operated-platform note under *Unforgeable*.

## Build Track level by build type

| Build type | Level | Note |
|---|---|---|
| Go | **Build L3** | Publishes inline; provenance + VSA follow (publish-before-verify, Distribution). |
| Python — pip | **Build L3** | — |
| Python — uv | **Build L3** | uv cache disabled on release (was L2 before [#226](https://github.com/TomHennen/wrangle/pull/226)). |
| npm | **Build L3** | Conditional on `npm ci` (cache not disabled on release — see Cache isolation). |
| npm — pnpm | **Build L3** | pnpm store cache disabled unconditionally. |
| Container | **Build L3** | Public registry only ([#182](https://github.com/TomHennen/wrangle/issues/182)); publishes inline. |
| Shell | **N/A** | No artifact → no provenance/VSA. Lint + tests + source scan only. |

All artifact-producing types meet the per-field and isolation requirements
**identically**, because they share one machinery: each `build_and_publish_*.yml`
runs `actions/attest-build-provenance` **inside the reusable workflow itself**,
so the workflow's `job_workflow_ref` is both the Sigstore signing-certificate
SAN and the provenance `builder.id`. The only axis that varies by build type is
the **Isolated → cache-poisoning** sub-point (see Cache isolation). Per-build-type
provenance policies live in `policies/wrangle-provenance-<type>-v1.hjson` (these,
**not** the unused `wrangle-default-v1.hjson`, are what the workflows evaluate).

## Provenance requirements

### Provenance Exists — `Build L1+`

- **Provenance identifies the output by cryptographic digest and describes how it
  was produced, in a format the ecosystem/consumer accepts** — MEETS. `attest`
  job runs `actions/attest-build-provenance` over SHA-256 subjects: python
  `build_and_publish_python.yml` (`subject-path: dist/*`), go (`subject-checksums:
  dist/checksums.txt`), container (`subject-digest`). Release-gated (`if:
  should-release`).
- **SLSA Provenance format RECOMMENDED** — MEETS. Predicate type
  `https://slsa.dev/provenance/v1`.
- **Alternate format must carry equivalent info** — N/A (SLSA format used).
- **Completeness best-effort at L1** — MEETS (informational at L1).

**Gap:** the **shell** build type produces no artifact and therefore no
provenance; it makes no Build Track claim.

### Provenance is Authentic — `Build L2+`

#### Authenticity (integrity + define-trust)

- **Consumer can verify the signature and that provenance wasn't tampered with**
  — MEETS. Keyless Sigstore/Fulcio signature over the DSSE envelope; consumers
  verify per [`verifying_artifacts.md`](verifying_artifacts.md).
- **Consumer can identify the build platform / entities** — MEETS. The consumer
  policy binds issuer + signer-workflow SAN: `policies/wrangle-vsa-consumer-v1.hjson`
  (`identities`), and the per-type provenance policy binds the generator identity,
  e.g. `policies/wrangle-provenance-python-v1.hjson`.

#### Signing methodology

- **Signature from a key accessible only to the provenance generator (SHOULD)** —
  MEETS. Keyless: an ephemeral Fulcio certificate minted from the `attest`/`verify`
  job OIDC token (`id-token: write`); no long-lived key.
- **Use transparency log / timestamping (RECOMMENDED)** — MEETS. Sigstore records
  the signing certificate in the Rekor transparency log (its inclusion timestamp
  is what lets a keyless VSA verify long after signing).

#### Accuracy (control-plane generation)

- **Provenance generated by the control plane, not a tenant** — MEETS.
  `attest-build-provenance` populates the predicate from the GitHub control plane;
  the build job cannot write it.
- **Platform prevents tenant tampering** — MEETS. Build jobs lack `id-token`, so
  they cannot mint a signing identity (see *Unforgeable*); adopter-controlled
  output is neutralized by the `::stop-commands::` guard.
- **Exception: subject digests / non-L2-required fields MAY be tenant-generated,
  and builders SHOULD document such cases** — MEETS *and disclosed here*: the
  artifact **`subject` digests are computed in the tenant build job** (the `hash`
  step, e.g. `build/actions/python/action.yml`), which is the spec's permitted
  exception. `resolvedDependencies` is likewise best-effort (below).

#### Completeness

- **`externalParameters` MAY be incomplete at L2; `resolvedDependencies`
  completeness is best-effort** — MEETS at L2 (the L3 `externalParameters`
  tightening is under *Unforgeable*).

### Provenance is Unforgeable — `Build L3`

> The spec section is **"Provenance Unforgeable"** (`#provenance-unforgeable`).

- **Secret material (signing key) stored in a secure system, accessible only to
  the build service account** — MEETS. Keyless: no stored key; the signing
  identity is an ephemeral OIDC-minted Fulcio cert.
- **Secret material NOT accessible to the environment running user-defined build
  steps** — MEETS. Build jobs hold only `contents: read` and **no `id-token`**
  (`build_and_publish_python.yml` build job; go `checks`); signing `id-token:
  write` exists only in the separate `attest`/`verify` jobs, which run no adopter
  code, on separate ephemeral VMs. (Go's `release` job holds `contents: write`
  for inline goreleaser publish but still **no `id-token`** — the separation
  holds.)
- **Every field generated or verified by the control plane; user build steps
  cannot inject or alter contents** — MEETS. Predicate is control-plane
  populated; adopter build/test output that could spoof workflow commands is
  wrapped by `lib/stop_commands_guard.sh` (wired in each `build/actions/<type>/`
  composite around the build/test/pack steps).
- **Completeness: `externalParameters` MUST be fully enumerated at L3;
  `resolvedDependencies` best-effort** — MEETS for `externalParameters` (the
  control plane records the full workflow invocation — repo, ref, workflow path);
  `resolvedDependencies` is the best-effort case (below).

**Self-operated platform:** L3 does not require the build platform to be operated
by a third party — only that the build is isolated from tenant control and the
provenance is unforgeable by the build process. An org running its **own fork**
(see [#395](https://github.com/TomHennen/wrangle/issues/395)) still meets this,
provided the build/sign job separation is preserved.

**Gap (direct composite use):** calling `build/actions/<type>/` directly from an
adopter-authored job forfeits the separation — one `id-token: write` on a job
that also runs the build breaks unforgeability. The supported L3 interface is the
reusable workflow (see [`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md)).

**Gap (builder == verifier):** wrangle's `verify` job (which emits the VSA) runs
in the same reusable workflow that built the artifact; SLSA guidance is that the
verifier should not be the builder of its own provenance. This affects the
*VSA's independence*, not the underlying `attest-build-provenance` provenance.
Post-v1.0 work — see [`ampel_research.md`](ampel_research.md).

### Provenance contents — per field (`build-provenance.md`)

| Field | Spec level | Verdict | Evidence |
|---|---|---|---|
| `buildDefinition`, `runDetails` | REQUIRED L1 | MEETS | Emitted by `attest-build-provenance`. |
| `buildType` | REQUIRED L1 | MEETS | `https://actions.github.io/buildtypes/workflow/v1`; checked by the `slsa-build-type` tenet in `wrangle-provenance-<type>-v1.hjson`. |
| `externalParameters` | REQUIRED L1; **MUST be complete at L3** | MEETS | Control-plane-populated workflow invocation (repo, ref, workflow path); source repo bound by the `slsa-build-point` tenet. |
| `internalParameters` | optional | N/A | Control-plane populated; not relied on. |
| `resolvedDependencies` | best-effort (through L3) | **GAP (disclosed)** | Records the source repo + digest, **not** the full transitive dependency closure with per-package digests — do not read the provenance as an attestation of every dependency. |
| `runDetails.builder.id` | REQUIRED L1; **sole determiner of the Build level**; different build modes MUST use different `builder.id` (and SHOULD use different signers) | MEETS | `job_workflow_ref` of the reusable workflow; baked `builderId` + `slsa-builder-id` tenet + signer SAN in each `wrangle-provenance-<type>-v1.hjson`. The per-build-type policy split **is** the spec's "different mode → different builder.id + signer". |
| `builderDependencies`, `builder.version` | optional | N/A | Not used. |
| `metadata.invocationId` / `startedOn` / `finishedOn` | no required level | MEETS | Control-plane populated (run id, timestamps). |
| `byproducts` | optional | N/A | Not used. |

- **Consumers MUST accept only specific (signer, builder.id) pairs** — MEETS.
  Enforced by the `identities` + `builderId` binding in each per-type policy and
  in `wrangle-vsa-consumer-v1.hjson`.
- **`builder.id` SHOULD resolve to documentation of scope / claimed level /
  accuracy + completeness guarantees and any tenant-generated fields** — **this
  document satisfies that SHOULD**: the claimed level is the table above, and the
  tenant-generated `subject` digests + best-effort `resolvedDependencies` are
  disclosed under *Authentic → Accuracy* and in this table.

## Build environment requirements

### Isolated — `Build L3`

> The build ran in an isolated environment free of unintended external
> influence; the platform MUST guarantee each of the following, even between
> builds in the same tenant.

- **A build cannot access the platform's secrets (the provenance signing
  material)** — MEETS. Build jobs `contents: read`, no `id-token` (see
  *Unforgeable*); adapters additionally run under `env -i` with a fixed
  allowlist (`run.sh`), so scan tools see no secrets.
- **Two builds overlapping in time cannot influence one another** — MEETS. Each
  job is a separate GitHub-hosted ephemeral VM; no shared mutable state except
  the GHA cache service (next sub-point).
- **No build can persist into or influence a later build's environment — an
  ephemeral environment is provisioned per build** — MEETS *(GitHub-hosted
  only)*. The runner image is re-provisioned per job; every checkout sets
  `persist-credentials: false`. **Precondition:** self-hosted runners void this.
- **No build can poison a cache another build uses (output identical with or
  without the cache)** — MEETS per build type; see **Cache isolation** below for
  the per-surface analysis (including the scan-job tool-build cache).
- **The platform opens no services for remote influence unless captured as
  `externalParameters`** — MEETS. No build composite opens listening/remote-control
  endpoints; outbound calls are dependency/registry fetches the build is a client
  of. No carve-out needed.

*Spec scope: L3 ensures a well-intentioned build runs securely; it does not stop
a producer from choosing a risky build, nor prohibit calling out to a
remote/self-hosted executor outside the platform's trust boundary — which is why
GitHub-hosted runners are a precondition here.*

### Hosted — `Build L2+`

- **All build steps ran on a hosted platform, not an individual workstation** —
  MEETS. Every job is `runs-on: ubuntu-latest` across all four
  `build_and_publish_*.yml` (build, attest, verify, scan, gate). **Precondition:**
  self-hosted runners void this.

## Producer requirements

These fall on the adopter (the *producer*); wrangle exists to satisfy them.

### Choose an appropriate build platform — `L1+`

- **Producer MUST select a platform capable of the desired level** — MEETS
  (enabled). Adopting wrangle's reusable workflow *is* choosing an L3-capable
  platform; the level table above is the claim.

### Follow a consistent build process — `L1+`

- **Producer MUST build consistently so verifiers can form expectations** —
  MEETS (enabled). The reusable workflow is the consistent process; the adopter's
  pinned config (`.goreleaser.yml`, `pyproject.toml`, lockfiles) is the
  per-project metadata.
- **If the package ecosystem needs a build-config file, the producer MUST keep
  it current** — adopter responsibility (e.g. `.goreleaser.yml` for Go); wrangle
  validates inputs but does not own the adopter's config.

### Distribute provenance — `L1+`

> The producer MUST distribute provenance to consumers, and MAY delegate that to
> the package ecosystem if the ecosystem can distribute it.

- **Producer distributes provenance to consumers** — MEETS. GitHub attestation
  store (`attestations: write` on the `attest` jobs); containers additionally as
  an OCI referrer on the image digest (`push-to-registry: true`). A per-artifact
  signed **VSA** is delivered as a release asset (Go/Python/npm) or a registry
  referrer (container).
- **Attestations SHOULD be bound to artifacts, not releases** — MEETS. Provenance
  subjects are per-artifact SHA-256 digests; the VSA is fanned out one-per-artifact
  via the dist-files matrix.
- **MAY delegate distribution to the ecosystem** — by design for **npm/python**:
  these workflows do not publish (publishing lives in the adopter's caller via
  Trusted Publishing), so the registry redistributes the provenance/attestation.
- **Publish-before-verify (Go + Container)** — documented gap. These publish
  inline (goreleaser / `docker push`) *before* the `attest`/`verify` jobs run; a
  verification failure fails the workflow conclusion but cannot un-publish.
  Consistent with SLSA's model — the contract is *"the consumer runs the
  verifier,"* not *"an attestation exists."* An artifact pulled during the gap, or
  after a verify failure, has no valid VSA and must be treated as untrusted.

## Cache isolation (per-surface detail for *Isolated → cache poisoning*)

A release build must not consume a shared cache that isn't re-verified on use.
Each build type reaches that bar differently. **The build cache for Go (and the
scan-job tool build) is not re-verified on hit** — which is exactly why it's
disabled on release; only the npm path keeps a cache enabled on release, and it
relies entirely on `npm ci`.

| Surface | PR / non-release | Release | Re-verified on hit? | Verdict | Evidence |
|---|---|---|---|---|---|
| **Scan-job Go / tool-build cache** | Opt-in, **off by default** (`go-cache` defaults to `''`); when `enabled`, `setup-go` restores module+build cache keyed on a staged `tools/go.sum`, reused by `run.sh`'s `go install tool`. | **Cold, forced** — all four `build_and_publish_*.yml` override `go-cache` to `''` when `should-release`, so the `setup-go` step is skipped and tools build with no cache. | Module half vs `go.sum` (GOPROXY/GOSUMDB pinned in `lib/env.sh`); **build half not** re-verified. | MEETS | `actions/scan/action.yml` (gated `setup-go` + stage key), `run.sh` (`go -C tools install tool`), `lib/env.sh` (GOPROXY/GOSUMDB), and the `should-release ? '' : go-cache` override in each `build_and_publish_*.yml`. `check_source_change.yml` passes `go-cache` through ungated — correct, it has no release/attest path. |
| **Go build (`setup-go`)** | `cache: enabled` → module+build cache. | `cache: disabled` → `cache: false`, cold. | Module vs `go.sum`; build cache **not**. | MEETS | `build/actions/go/{checks,release}/action.yml`; release-gated in `build_and_publish_go.yml`. |
| **Python uv (`setup-uv`)** | `enable-cache: true`. | `cache: disabled` → `enable-cache: false`, cold. | uv does **not** re-hash on hit. | MEETS (was the L2 gap; [#226](https://github.com/TomHennen/wrangle/pull/226)) | `build/actions/python/action.yml`; gated in `build_and_publish_python.yml`. |
| **Python pip** | No `setup-python` cache, ever. | Same. | N/A. | MEETS | `build/actions/python/action.yml` (no `cache:`). |
| **npm (`setup-node` + `npm ci`)** | `cache: npm`. | **Identical — not disabled on release.** | `npm ci` re-verifies each cached tarball vs `package-lock.json`. | MEETS — **conditional on `npm ci`** (the one surface with no cold-on-release fallback) | `build/actions/npm/action.yml`, `detect_tooling.sh`, `build_and_pack.sh` (`npm ci`). |
| **pnpm (`setup-node`)** | Cache disabled (empty). | Same. | N/A. | MEETS | `build/actions/npm/detect_tooling.sh`. |
| **Container (BuildKit `type=gha`)** | `pr-cache` (default `isolated`, per-PR scope). | **`disabled` forced** when `should-release`. | Not re-verified; PR scope sanitized (`tr -c 'a-zA-Z0-9._-' '_'`, `LC_ALL=C`) to block `,type=registry` injection. | MEETS | `build/actions/container/{action.yml,resolve_cache.sh,validate_inputs.sh}`; gated in `build_and_publish_container.yml`. |

Adapters/scan tools receive **no secrets** (`run.sh` strips the environment with
`env -i`); `GITHUB_TOKEN` is granted only to the steps that publish.

## General requirements

- **All implementations MUST use industry security best practices** — access
  controls, secured communications, cryptographic-secret management, frequent
  updates, prompt vulnerability fixes — MEETS. wrangle's posture: SHA-pinned
  actions, least-privilege per-job `permissions`, keyless signing, the source
  scan (OSV/Zizmor) gating every build, and the supply-chain discipline in
  [`DEP_MGMT.md`](../DEP_MGMT.md).

## Maintaining this page

A living document: when a build type's mechanism changes, update the relevant
sub-point and its evidence in the same PR — including new cache surfaces. The
historical *why* behind each hardening step stays in
[`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md).
