# SLSA Build Track conformance

Wrangle's goal is to **prove that a single reusable-workflow call can produce a
verifiable SLSA Build L3 artifact** — without the adopter wiring up provenance,
signing, or verification themselves. This page is the maintained, current claim
that backs that goal: for each build type, exactly which SLSA v1.2 Build Track
requirements wrangle meets, with `file:line` evidence you can re-verify.

It is the **source of truth for the level wrangle claims.**
[`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md) is the point-in-time isolation review that
drove the hardening behind these claims; treat it as the historical record, and
this page as the live state. Requirement clauses and quotes come from
[SLSA v1.2 build-requirements](https://slsa.dev/spec/v1.2/build-requirements).

## Scope and preconditions

Every claim below holds **only** under these conditions — they are part of the
claim, not footnotes:

- **Reusable-workflow consumption only.** The L3 verdicts apply when an adopter
  calls `TomHennen/wrangle/.github/workflows/build_and_publish_<type>.yml`.
  Calling the composite actions under `build/actions/<type>/` directly is **not
  an L3 path** — it forfeits the build-vs-sign job separation that makes
  provenance non-forgeable (one stray `id-token: write` on the build job breaks
  it). See [`SLSA_L3_AUDIT.md` "Direct composite consumption"](SLSA_L3_AUDIT.md).
- **GitHub-hosted runners only.** The Hosted / Isolated / Ephemeral verdicts
  assume GitHub-hosted runners; self-hosted runners invalidate them.
- **Builder ≠ verifier is not yet separated.** Wrangle's `verify` job (which
  emits the VSA) runs in the *same* reusable workflow that builds the artifact.
  Per SLSA's guidance the verifier should not be the builder of its own
  provenance; this affects the *VSA's independence*, not the underlying
  `attest-build-provenance` provenance (whose build/sign separation does hold).
  Tracked as post-v1.0 work — see [`ampel_research.md`](ampel_research.md).

## Summary — Build Track level by build type

| Build type | Level | Note |
|---|---|---|
| Go | **Build L3** | Publishes inline (goreleaser); provenance + VSA follow — see "publish-before-verify" below. |
| Python — pip | **Build L3** | — |
| Python — uv | **Build L3** | uv cache disabled on release builds (was L2 before [PR #226](https://github.com/TomHennen/wrangle/pull/226)). |
| npm | **Build L3** | Conditional on `npm ci` re-verifying cached tarballs (see cache table). |
| npm — pnpm | **Build L3** | pnpm store cache disabled unconditionally. |
| Container | **Build L3** | Public registry (e.g. ghcr.io) only; publishes inline — see below. Private repos unsupported ([#182](https://github.com/TomHennen/wrangle/issues/182)). |
| Shell | **N/A** | No artifact, so no provenance/VSA. Lint + tests + source scan only. |

## Requirement-by-requirement (common platform)

These hold identically across all artifact-producing build types, because they
come from shared machinery: each `build_and_publish_*.yml` runs
`actions/attest-build-provenance` **inside the reusable workflow itself**, so
the workflow's `job_workflow_ref` is both the Sigstore signing-certificate SAN
and the provenance `builder.id`. (That the four workflows carry the *identical*
attest pin and the identical build-job-`contents: read` / attest-job-`id-token:
write` split is itself the evidence this is platform-level, not per-type.)

| SLSA requirement | Level | Verdict | Evidence (current code) |
|---|---|---|---|
| **Provenance Exists** | L1 | MEETS | `attest` job runs `actions/attest-build-provenance` over each artifact's SHA-256 subject — `build_and_publish_{python,npm,go,container}.yml` (`attest` job). Release-gated (`if: should-release`). |
| **Contents — `builder.id`** | L1+ | MEETS | `builder.id` is the reusable workflow's `job_workflow_ref` (attest runs inside it, post-#316) — workflow comments in each `attest` job; [`SLSA_L3_AUDIT.md` #316 update](SLSA_L3_AUDIT.md). |
| **Contents — `buildType`** | L1+ | MEETS | `https://actions.github.io/buildtypes/workflow/v1`, predicate `slsa.dev/provenance/v1`, set by `attest-build-provenance`. |
| **Contents — `externalParameters` / source** | L1+ | MEETS | Control-plane-populated from the `github` context; build jobs check out the triggering SHA (`actions/checkout`). Tenant code cannot rewrite these fields. |
| **Contents — `resolvedDependencies` / materials** | L1+ | **PARTIAL** | The `workflow/v1` buildType records the source repo + digest as the resolved input; it does **not** enumerate the full transitive dependency closure with per-package digests. Stated honestly so consumers don't over-read it. |
| **Contents — `metadata`** | L1+ | MEETS | Run id / timestamps populated by the GitHub control plane (same trust basis as `builder.id`). |
| **Provenance is Authentic (signed)** | L2 | MEETS | Keyless Sigstore/Fulcio via the `attest` job's OIDC (`id-token: write`); signer SAN = the reusable workflow ref. |
| **Provenance is Unforgeable** | **L3** | MEETS | Build jobs hold only `contents: read` and **no `id-token`** (cannot mint a signing token); signing lives only in the separate `attest`/`verify` jobs, which run no adopter code. Separate per-job runner VMs. The `::stop-commands::` guard wraps every step that runs adopter-controlled code/output. |
| **Isolated** | **L3** | MEETS | Reusable workflow is the isolated trusted platform; the cache-poisoning sub-requirement is met per the cache table below. |
| **Hosted** | L2 | MEETS | All jobs `runs-on: ubuntu-latest`. |
| **Ephemeral environment** | **L3** | MEETS | GitHub-hosted runners are provisioned fresh per job; build / attest / verify are separate jobs → separate ephemeral VMs. |
| **Provenance distribution** | L1+ | MEETS | GitHub attestation store (`attestations: write`); OCI referrer on the image digest for containers (`push-to-registry: true`); provenance bundle + per-artifact signed VSA delivered as release assets (file types) or registry referrers (containers). |

## The one axis that varies: cache / secret isolation on release builds

"Isolated" at L3 forbids a release build from consuming a shared cache that
isn't re-verified on use. Each build type reaches that bar differently — this is
the load-bearing per-type difference and where the audit's findings lived:

| Build type | Mechanism | Verdict | Evidence |
|---|---|---|---|
| **Go** | Module cache re-verified against `go.sum` on load (npm-ci-like); build cache *and* module cache disabled on release (`cache: disabled` → `setup-go` `cache: false`). | MEETS | `build_and_publish_go.yml` (`checks`/`release` `cache` inputs); `build/actions/go/SPEC.md` "Cache isolation". |
| **Python — pip** | Never opts into `setup-python`'s pip cache; per-run/ephemeral only. | MEETS | `build/actions/python/action.yml` `Setup Python` step (no `cache:`). |
| **Python — uv** | uv cache enabled for PRs but **disabled on release builds** (`cache: disabled` → `setup-uv` `enable-cache: false`); uv does not re-hash on cache hit. | MEETS (was the L2 gap; fixed in [#226](https://github.com/TomHennen/wrangle/pull/226)) | `build_and_publish_python.yml` build-job `cache` input (`should-release ? disabled : enabled`); `build/actions/python/action.yml` `enable-cache`. |
| **npm** | `setup-node` cache stays **enabled**, safe only because install is `npm ci`, which re-verifies every cached tarball against `package-lock.json` on every install. | **MEETS — conditional on `npm ci`** | `build/actions/npm/build_and_pack.sh` (`npm ci`); audit `^npmci` footnote. ⚠️ Replacing `npm ci` with `npm install` would break this. |
| **npm — pnpm** | `setup-node` cache **disabled** (PR and release alike) because the pnpm store has no install-time re-verification. | MEETS | `build/actions/npm/detect_tooling.sh` (empty cache on pnpm path). |
| **Container** | BuildKit cache forced to `disabled` on release builds; an allowlist gate fails the build on a bad `cache` value so it can't silently fall back to cache-on. PR-scope cache key is sanitized before reaching the comma-delimited BuildKit config (blocks `,type=registry,ref=…` injection). | MEETS (was the L2 gap; fixed in [#226](https://github.com/TomHennen/wrangle/pull/226)) | `build_and_publish_container.yml` build-job `cache` input; `build/actions/container/{validate_inputs,resolve_cache}.sh`. |

In all cases adapters/scan tools receive **no secrets** (the orchestrator strips
the environment), and `GITHUB_TOKEN` is granted only to the steps that publish.

## Publish-before-verify (Go and Container)

Go (goreleaser) and Container (`docker push`) publish the artifact **inline,
before** the `attest`/`verify` jobs run. There is no rollback: a verification
failure fails the workflow conclusion but cannot un-publish. This is consistent
with SLSA's model — the contract is *"the consumer runs the verifier,"* not
*"an attestation exists."* An artifact downloaded during the gap (or after a
verify failure) has no valid VSA and must be treated as untrusted. The bytes the
`attest` job signs are content-addressed, so the provenance is still sound for
what it covers. Verbatim acknowledgement lives in the workflow comments
(`build_and_publish_go.yml`, `build_and_publish_container.yml`); the consumer
verification commands are in each build type's README and
[`verifying_artifacts.md`](verifying_artifacts.md).

## Known limitations (do not over-read the claim)

- **Direct composite consumption is not L3** (see Scope). The supported L3
  interface is the reusable workflow.
- **Builder == verifier** in the same workflow is not strictly L3-compliant for
  verifier independence (post-v1.0 work).
- **`resolvedDependencies` is source-level, not full dependency closure**
  (table above).
- **Container: public registries only**; private-repo referrer verification is
  unsupported ([#182](https://github.com/TomHennen/wrangle/issues/182)).
- **Self-hosted runners invalidate** the Hosted / Isolated / Ephemeral verdicts.
- **Shell makes no Build Track claim** — it produces no artifact.

## Maintaining this page

This is a living document: when a build type's mechanism changes, update the
cell and its evidence in the same PR. The historical *why* behind each hardening
step stays in [`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md); the current *what* lives
here.
