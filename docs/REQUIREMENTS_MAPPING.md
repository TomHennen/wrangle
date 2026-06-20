# SLSA Build Track requirements mapping

Wrangle's goal is to **prove a single reusable-workflow call can hand a developer
SLSA Build L3 provenance, a signed VSA, source scanning, an SBOM, and more** —
without wiring any of it up. This document maps wrangle against the
[SLSA v1.2 Build Track](https://slsa.dev/spec/v1.2/build-requirements)
specifically: each requirement, broken down to its individual MUST/SHOULD
sub-points, with a verdict and evidence you can re-verify. (Read the requirement
text at the spec link above; it's paraphrased here.)

[`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md) is an earlier point-in-time audit that drove
a number of hardening changes; its findings no longer hold. **This document** is the
authoritative analysis of how wrangle meets SLSA Build L3. Verdicts: **MEETS** (a
"(caveat)" / "disclosed limitation" flags a documented residual that doesn't void
it) / **GAP** (genuinely unmet) / **N/A**.

## Scope and preconditions

Every verdict holds **only** under these conditions — they are part of the claim:

- **Reusable-workflow consumption only.** Verdicts apply when an adopter calls
  `TomHennen/wrangle/.github/workflows/build_and_publish_<type>.yml`. Calling the
  `build/actions/<type>/` composites directly is **not** an L3 path (see
  *Unforgeable* → direct-composite gap).
- **GitHub-hosted runners only.** Self-hosted runners void the Isolated and
  Hosted verdicts (restated on each).
- **Operator may be the source owner.** L3 does not require the build platform to
  be run by a third party, so an org running its **own fork** of wrangle is in
  scope ([#395](https://github.com/TomHennen/wrangle/issues/395)) as long as the
  build/sign job separation is preserved.

## Build Track level by build type

Each row links the reusable workflow it covers. pip/uv and npm/pnpm are
package-manager options within one workflow each, not separate L3 surfaces.

| Build type | Level | Note |
|---|---|---|
| [Go](../.github/workflows/build_and_publish_go.yml) | **Build L3** | Publishes inline (publish-before-verify — see Distribution). |
| [Python](../.github/workflows/build_and_publish_python.yml) (pip, uv) | **Build L3** | Cache handling differs between pip and uv — see Cache isolation. |
| [npm](../.github/workflows/build_and_publish_npm.yml) (npm, pnpm) | **Build L3** | npm keeps its cache on release, relying on `npm ci` — see Cache isolation. |
| [Container](../.github/workflows/build_and_publish_container.yml) | **Build L3** | Public registry only ([#182](https://github.com/TomHennen/wrangle/issues/182)); publishes inline. |
| [Shell](../.github/workflows/build_shell.yml) | **N/A** | No artifact → no provenance/VSA. Lint + tests + source scan only. |

All artifact-producing types share one machinery: each `build_and_publish_*.yml`
runs `actions/attest-build-provenance` **inside the reusable workflow itself**, the
signing-certificate SAN is that workflow's own path (per build type — see *builder
identity* below), and the per-type provenance policy is
`policies/wrangle-provenance-<type>-v1.hjson`. The only requirement that varies by
build type is the **Isolated → cache** sub-point.

## Provenance requirements

### Provenance Exists — `Build L1+`

- **Provenance identifies the output by cryptographic digest and describes how it
  was produced, in a format the ecosystem/consumer accepts** — MEETS. The
  `attest` job runs `actions/attest-build-provenance` over SHA-256 subjects:
  python `subject-path: dist/*`, go `subject-checksums: dist/checksums.txt`,
  container `subject-digest`.
- **SLSA Provenance format RECOMMENDED** — MEETS. Predicate
  `https://slsa.dev/provenance/v1`.
- **Alternate format must carry equivalent info** — N/A (SLSA format used).

**Gap:** the **shell** build type produces no artifact and so no provenance.

### Provenance is Authentic — `Build L2+`

#### Authenticity (integrity + define-trust)

- **Consumer can verify the signature and that provenance wasn't tampered with**
  — MEETS. Keyless Sigstore/Fulcio signature over the DSSE envelope; consumers
  verify per [`verifying_artifacts.md`](verifying_artifacts.md).
- **Consumer can identify the build platform and entities to trust** — MEETS. The
  consumer's `ampel verify` (policy `wrangle-vsa-consumer-v1.hjson`) checks two
  bound identities:
  - the **signer** is a wrangle reusable workflow, e.g.
    `https://github.com/TomHennen/wrangle/.github/workflows/build_and_publish_python.yml@<ref>` (the Fulcio cert SAN);
  - the build ran in **your own repo** — the cert's source-repository extension
    must equal the `sourceRepo` *the consumer passes* (`https://github.com/<your-org>/<your-repo>`).
  Both must match, so a wrangle-signed artifact from someone else's repo is
  rejected.

#### Signing methodology

- **Signature from a key accessible only to the provenance generator (SHOULD)** —
  MEETS, via isolation rather than "no key": signing runs in the `attest`/`verify`
  jobs, which hold `id-token: write` and run **no adopter code**; the build jobs
  have **no `id-token`**, so the OIDC credential and the ephemeral Fulcio key
  never exist in the environment that runs user build steps. wrangle holds no
  long-lived signing key — the root of trust is Sigstore's (Fulcio/Rekor).
- **Use a transparency log / timestamping (RECOMMENDED)** — MEETS. The signing
  cert is logged in Rekor; its inclusion timestamp is what lets a keyless VSA
  verify long after the short-lived cert expires.

#### Accuracy (control-plane generation)

- **Provenance generated by the control plane, not a tenant** — MEETS.
  `attest-build-provenance` populates the predicate from the GitHub control plane.
- **Platform prevents tenant tampering** — MEETS. Build jobs can't mint a signing
  identity (no `id-token`); adopter build/test output that could spoof workflow
  commands is wrapped by the `::stop-commands::` guard.
- **Exception — subject digests / non-L2-required fields MAY be tenant-generated,
  and builders SHOULD document it** — MEETS *and disclosed*: the artifact
  `subject` digests are computed in the tenant build job (the `hash` step), which
  is the spec's permitted exception; `resolvedDependencies` is best-effort
  (below).
- **Completeness SHOULD hold at L2** — MEETS. `externalParameters` MAY be
  incompletely captured at L2 (it becomes MUST-complete at L3, under
  *Unforgeable*); resolved-dependency completeness is best-effort.

### Provenance is Unforgeable — `Build L3`

> Spec section: **"Provenance Unforgeable"** (`#provenance-unforgeable`).

#### Signing secret stored securely, reachable only by the build service account

MEETS, **with a caveat**. There is no long-lived signing key to store or steal: the
per-run credential is the OIDC token + an ephemeral (~minutes) Fulcio key, held only
by the isolated `attest`/`verify` jobs. The "secure management system" here is GitHub
OIDC + Sigstore + per-job runner isolation — **not** a wrangle-operated KMS/HSM.

**Residual risk:** keyless reduces but does not eliminate credential theft. The
signing jobs run **no adopter code**, so the realistic vector is a wrangle-side
supply-chain compromise — a malicious dependency in one of wrangle's *own* pinned
signing-job actions (governed by [`DEP_MGMT.md`](../DEP_MGMT.md)) — or a runner
compromise; either could exfiltrate the short-lived token/key within its validity
window. We don't claim KMS/HSM-grade key custody.

#### Signing secret not accessible to the environment running user build steps

MEETS, and this is the load-bearing control: **no build job holds `id-token: write`**;
only the separate `attest`/`verify` jobs (no adopter code, separate VMs) get it. Build
jobs otherwise carry only what they need to publish — the Go `release` job adds
`contents: write` (goreleaser) and the container `build` job adds `packages: write`
(push the image), neither with `id-token`. This is exactly the defense against the
"leaked id-token" failure mode — the token is never granted to a job that runs tenant
code.

#### Every field generated or verified by the control plane

MEETS. Predicate is control-plane populated; the `::stop-commands::` guard
(`lib/stop_commands_guard.sh`, wired in each `build/actions/<type>/` composite)
neutralizes workflow-command injection from build output, so user steps can't inject
or alter provenance fields.

#### Completeness — `externalParameters` MUST be fully enumerated at L3

MEETS; the control plane records the full workflow invocation (repo, ref, workflow
path). `resolvedDependencies` remains best-effort (a disclosed limitation, below).

**Gap (direct composite use):** calling `build/actions/<type>/` directly forfeits
the build/sign separation — one `id-token: write` on a job that also runs the
build breaks unforgeability. The supported L3 interface is the reusable workflow.

**Gap (builder == verifier):** wrangle's `verify` job (which emits the VSA) runs
in the same reusable workflow that built the artifact; SLSA guidance is that the
verifier should not be the builder of its own provenance. This affects the
*VSA's independence*, not the underlying `attest-build-provenance` provenance. It
also **compounds with the own-fork allowance** (Scope): one party can own the
source, operate the builder, and sign the VSA — still within L3 (which constrains
the build platform's integrity, not third-party operation), but worth naming.
Post-v1.0 — see [`ampel_research.md`](ampel_research.md).

### Provenance contents — per field (`build-provenance.md`)

| Field | Spec level | Verdict | Evidence |
|---|---|---|---|
| `buildDefinition`, `runDetails` | REQUIRED L1 | MEETS | Emitted by `attest-build-provenance`. |
| `buildType` | REQUIRED L1 | MEETS | `https://actions.github.io/buildtypes/workflow/v1`; `slsa-build-type` tenet. |
| `externalParameters` | REQUIRED L1; **complete at L3** | MEETS | Control-plane workflow invocation (repo, ref, workflow path); source repo bound by `slsa-build-point`. |
| `internalParameters` | optional | N/A | Not relied on. |
| `resolvedDependencies` | best-effort (through L3) | MEETS (disclosed limitation) | Best-effort is satisfied by the source repo + digest; the **transitive dependency closure is not enumerated** — do not read the provenance as an attestation of every dependency. |
| `runDetails.builder.id` | REQUIRED L1; **different build modes MUST use a different `builder.id`** (SHOULD use a different signer) | MEETS — see *builder identity* below | per-type signer SAN + baked `builderId` in `wrangle-provenance-<type>-v1.hjson`. |
| `metadata.invocationId/startedOn/finishedOn` | no required level | MEETS | Emitted by `attest-build-provenance` where present (control-plane populated; none required). |
| `builderDependencies`, `builder.version`, `byproducts` | optional | N/A | Not used. |

These cells are artifact-backed, not prose-only: `test/consumer/verify_consumer_provenance.bats`
verifies a real signed `attest-build-provenance` capture per artifact-producing build type
(go, python, npm, container) against the shipped `wrangle-provenance-<type>-v1.hjson`, then
asserts each field above (predicate type, `buildType`, per-type `builder.id`,
`externalParameters` keys, `metadata.invocationId`, `resolvedDependencies` shape) — so a
provenance-shape change that voids a MEETS cell fails CI. `metadata.startedOn/finishedOn` are
not emitted, which is why the row scopes to "where present".

**Builder identity.** wrangle sets `builder.id` to the reusable workflow's own path —
`https://github.com/TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@<ref>`
for Go, `…/build_and_publish_python.yml@<ref>` for Python, and so on (verified on a
recent build; `<ref>` is whatever the adopter pinned). Each workflow builds exactly one
way and claims one Build Level, so a different build mode is a different workflow is a
different `builder.id` — which is what the spec's "different mode → different
`builder.id`" MUST asks for. This is **distinct** from `externalParameters.workflow`,
the adopter's *caller* workflow (e.g. `<your-repo>/.github/workflows/release.yml`): the
provenance separates *who built it* (wrangle) from *what invoked the build* (the
adopter).

wrangle binds that identity **when it emits the VSA** (`wrangle-provenance-<type>-v1.hjson`
requires both the per-type `builder.id` and the matching signer). The **consumer** policy
then checks the VSA's signer, your source repo, the resource URI, and the L3 verdict —
not `builder.id` directly — so consumers rely on wrangle's verifier for the per-type bind
(the builder == verifier delegation noted above).

- **Consumers MUST accept only specific (signer, builder.id) pairs** — MEETS: wrangle
  binds the pair at VSA emission; the consumer binds the VSA signer and trusts wrangle's
  verifier for the rest.
- **`builder.id` SHOULD resolve to docs of scope / level / accuracy + completeness** —
  MEETS in substance: wrangle publishes this page (claimed level, plus the
  tenant-generated `subject` and best-effort `resolvedDependencies` disclosures). The
  `builder.id` URI resolves to the workflow source, not to this page, so the SHOULD is
  met by intent.

## Build environment requirements

### Isolated — `Build L3`

> The build ran isolated from unintended external influence; the platform MUST
> guarantee each of the following, even between builds in the same tenant.

- **A build can't reach the platform's secrets (the signing material)** — MEETS.
  **No build job holds `id-token: write`** — the load-bearing fact (a build job
  can't mint the signing identity). Build jobs are otherwise minimal-permission
  (`contents: read`; the Go `release` job adds `contents: write` and the container
  `build` job adds `packages: write` to publish, neither with `id-token`).
  Adapters run under `env -i` with a fixed allowlist (`run.sh`), and every
  checkout sets `persist-credentials: false`, so the build environment sees no
  platform secrets.
- **Overlapping builds can't influence one another** — MEETS. Each job is a
  separate GitHub-hosted ephemeral VM.
- **No build persists into a later build's environment (ephemeral per build)** —
  MEETS *(GitHub-hosted only)*. GitHub re-provisions a fresh runner VM per job, so
  nothing carries to the next build. **Precondition:** self-hosted runners void
  this.
- **No cache poisoning (output identical with or without the cache)** — MEETS per
  build type; see **Cache isolation**.
- **No services opened for remote influence unless captured as
  `externalParameters`** — MEETS. No build composite opens remote-control
  endpoints; outbound calls are dependency/registry fetches the build is a client
  of.

### Hosted — `Build L2+`

- **All steps ran on a hosted platform, not a workstation** — MEETS. Every job is
  `runs-on: ubuntu-latest`. **Precondition:** self-hosted runners void this.

## Producer requirements

These fall on the adopter (the *producer*); wrangle exists to satisfy them.

- **Choose an appropriate build platform** — MEETS (enabled). Adopting wrangle's
  reusable workflow *is* choosing an L3-capable platform.
- **Follow a consistent build process** — MEETS (enabled). The reusable workflow
  is the consistent process; the adopter's pinned config (`.goreleaser.yml`,
  `pyproject.toml`, lockfiles) is their per-project metadata, which they keep
  current.
- **Distribute provenance (MAY delegate to the ecosystem)** — MEETS for the build
  **provenance**: it lands in the GitHub attestation store (`attestations: write`),
  and for containers also as an OCI referrer on the image digest. The signed
  **VSA** is delivered as: a GitHub release asset for **Go** (goreleaser creates
  the release inline); a release asset for **Python/npm** *only if the adopter's
  tooling created a release for the tag*, otherwise the run-scoped workflow
  artifact; for **container** the VSA pushed as its own OCI referrer on the
  image digest, plus the combined bundle as a run-scoped workflow artifact.
  **Enabled, not executed:** for
  Python/npm wrangle stops before publish (publishing is the adopter's caller via
  Trusted Publishing), so whether the *registry* redistributes provenance is the
  adopter's step — wrangle enables it but does not perform it.
- **Attestations SHOULD be bound to artifacts, not releases** — MEETS.
  Per-artifact digest subjects + a one-per-artifact VSA matrix.

**Publish-before-verify (Go + Container):** these publish inline (goreleaser /
`docker push`) *before* `attest`/`verify` run; a verify failure fails the run but
can't un-publish. Consistent with SLSA — the contract is *"the consumer runs the
verifier."* An artifact pulled during the gap, or after a verify failure, has no
valid VSA and must be treated as untrusted.

## Cache isolation (the *Isolated → cache poisoning* sub-point)

Only **release** builds produce attested artifacts, so only release behavior
bears on L3: a release build must not consume a shared cache that isn't
re-verified on use. (PR builds may cache freely; they produce no provenance.)
Note that the Go and scan-job **build** caches are *not* re-verified on hit —
which is why they're forced cold on release; npm is the one surface that keeps a
cache on release, relying on `npm ci`.

| Surface | On release | Re-verified on hit? | Verdict |
|---|---|---|---|
| Scan-job Go / tool-build cache | Cold (forced off when `should-release`) | n/a | MEETS — scan output gates the build but isn't an attested artifact |
| Go build (`setup-go`) | Cold (`cache: false`) | n/a | MEETS |
| Python uv | Cold (`enable-cache: false`) | n/a | MEETS |
| Python pip | No cache, ever | n/a | MEETS |
| npm | **Cache stays on** | Yes — `npm ci` re-verifies each tarball vs the lockfile | MEETS — rests on `npm ci` |
| pnpm | Cold (cache disabled) | n/a | MEETS |
| Container | Cold (`disabled` when `should-release`) | n/a | MEETS — PR scope also sanitized to block `,type=registry` injection |

Evidence: the `should-release ? cold : …` overrides in each
`build_and_publish_*.yml`; `actions/scan/action.yml` + `run.sh` + `lib/env.sh`
(scan cache + GOPROXY/GOSUMDB pin); `build/actions/{go,python,npm,container}/`
helpers; `build/actions/npm/build_and_pack.sh` (`npm ci`).

## General requirements

- **All implementations MUST use industry security best practices** (access
  control, secure comms, secret management, frequent updates, prompt fixes) —
  MEETS. SHA-pinned actions, least-privilege per-job `permissions`, keyless
  signing, the source scan gating every build, and the discipline in
  [`DEP_MGMT.md`](../DEP_MGMT.md).

## Maintaining this page

A living document: when a build type's mechanism changes, update the relevant
sub-point and its evidence in the same PR — including new cache surfaces. The
historical *why* stays in [`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md).
