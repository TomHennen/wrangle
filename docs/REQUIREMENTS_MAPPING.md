# SLSA Build Track requirements mapping

Wrangle's goal is to **prove that a single reusable-workflow call can produce a
verifiable SLSA Build L3 artifact** — without the adopter wiring up provenance,
signing, or verification themselves. This document is the maintained claim
behind that goal: each SLSA v1.2 Build Track requirement, and how wrangle meets
it, with evidence you can re-verify. It mirrors the SLSA project's own
[`source-tool` requirements mapping](https://github.com/slsa-framework/source-tool/blob/main/docs/REQUIREMENTS_MAPPING.md)
for the Source Track.

It is the **source of truth for the level wrangle claims.**
[`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md) is the point-in-time isolation review that
drove the hardening behind these claims — read it for the *why*, this page for
the *what*. Requirement names link to
[SLSA v1.2 build-requirements](https://slsa.dev/spec/v1.2/build-requirements).

## Scope and preconditions

Every claim below holds **only** under these conditions — they are part of the
claim, not footnotes:

- **Reusable-workflow consumption only.** The verdicts apply when an adopter
  calls `TomHennen/wrangle/.github/workflows/build_and_publish_<type>.yml`.
  Calling the composite actions under `build/actions/<type>/` directly is **not
  an L3 path** (see the Non-forgeable gap).
- **GitHub-hosted runners only.** Self-hosted runners invalidate the Hosted /
  Isolated / Ephemeral verdicts.
- **The build platform is trusted and isolated regardless of who operates it.**
  The analysis treats wrangle's reusable workflow as the isolated build
  platform; it does not assume the platform operator is a third party distinct
  from the source's owner. An org that runs its **own fork** is therefore still
  in scope (and is the canonical SLSA "operate your own builder" posture) — see
  the "self-operated platform" note under Non-forgeable.

## Build Track level by build type

| Build type | Level | Note |
|---|---|---|
| Go | **Build L3** | Publishes inline; provenance + VSA follow (see the publish-before-verify gap). |
| Python — pip | **Build L3** | — |
| Python — uv | **Build L3** | uv cache disabled on release builds (was L2 before [#226](https://github.com/TomHennen/wrangle/pull/226)). |
| npm | **Build L3** | Conditional on `npm ci` re-verifying cached tarballs (Isolated gap). |
| npm — pnpm | **Build L3** | pnpm store cache disabled unconditionally. |
| Container | **Build L3** | Public registry only ([#182](https://github.com/TomHennen/wrangle/issues/182)); publishes inline. |
| Shell | **N/A** | No artifact → no provenance/VSA. Lint + tests + source scan only. |

All artifact-producing types meet the requirements below **identically**,
because they share one machinery: each `build_and_publish_*.yml` runs
`actions/attest-build-provenance` **inside the reusable workflow itself**, so
the workflow's `job_workflow_ref` is both the Sigstore signing-certificate SAN
and the provenance `builder.id`. The only requirement that varies by build type
is **Isolated** (cache handling) — called out per-type there.

## Provenance requirements

### [Provenance Exists](https://slsa.dev/spec/v1.2/build-requirements)
**Required for: SLSA Build Level 1+**
Every released artifact gets SLSA Provenance v1, produced by the `attest` job's
`actions/attest-build-provenance` over the artifact's SHA-256 subject
(`subject-checksums` / `subject-path` / `subject-digest`). Release-gated
(`if: should-release`). Evidence: the `attest` job in each
[`build_and_publish_*.yml`](../.github/workflows/).
**Gap:** the **shell** build type produces no artifact and therefore no
provenance — it makes no Build Track claim.

### [Provenance Contents](https://slsa.dev/spec/v1.2/build-requirements)
**Required for: SLSA Build Level 1+**
`attest-build-provenance` populates the predicate from the GitHub control plane,
so the tenant build cannot rewrite it:
- `builder.id` = the reusable workflow's `job_workflow_ref` (attest runs inside
  it; see [`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md) #316 update).
- `buildType` = `https://actions.github.io/buildtypes/workflow/v1`.
- `externalParameters` / source = the triggering repo + commit (the build job
  checks out the triggering SHA).
- `metadata` = run id / timestamps from the control plane.

**Gap:** `resolvedDependencies` records the **source repo + digest**, not the
full transitive dependency closure with per-package digests. Consumers should
not read the provenance as an attestation of every dependency.

### [Provenance is Authentic](https://slsa.dev/spec/v1.2/build-requirements)
**Required for: SLSA Build Level 2+**
The VSA and provenance are keyless-signed via the `attest`/`verify` jobs' OIDC
token (`id-token: write`), through Sigstore/Fulcio; the signing certificate's
SAN is the reusable workflow's ref. Consumers verify against that identity
(`policies/wrangle-vsa-consumer-v1.hjson`; the documented commands in
[`verifying_artifacts.md`](verifying_artifacts.md)).

### [Provenance is Non-forgeable](https://slsa.dev/spec/v1.2/build-requirements)
**Required for: SLSA Build Level 3**
The signing identity is unreachable by the code being built. Build jobs hold
only `contents: read` and **no `id-token`**, so they cannot mint a signing
token; signing lives only in the separate `attest`/`verify` jobs, which run no
adopter code, on separate ephemeral runner VMs. Steps that execute
adopter-controlled code or echo adopter-controlled output are wrapped by the
`::stop-commands::` guard ([`lib/stop_commands_guard.sh`](../lib/stop_commands_guard.sh))
so build output cannot inject workflow commands.

**Self-operated platform:** L3 does not require the build platform to be
operated by a third party — only that the build is isolated from tenant control
and the provenance non-forgeable by the build process. An org running its own
fork (see [#395](https://github.com/TomHennen/wrangle/issues/395)) still meets
this, provided the build/sign job separation is preserved.

**Gap (direct composite use):** calling `build/actions/<type>/` directly from an
adopter-authored job forfeits this separation — a single `id-token: write` on a
job that also runs the build breaks non-forgeability. The supported L3 interface
is the reusable workflow. See [`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md) "Direct
composite consumption".

**Gap (builder == verifier):** wrangle's `verify` job (which emits the VSA) runs
in the same reusable workflow that built the artifact. SLSA guidance is that the
verifier should not be the builder of its own provenance; this affects the
*VSA's independence*, not the underlying `attest-build-provenance` provenance.
Tracked as post-v1.0 work — see [`ampel_research.md`](ampel_research.md).

## Build environment requirements

### [Isolated](https://slsa.dev/spec/v1.2/build-requirements)
**Required for: SLSA Build Level 3**
The reusable workflow is the isolated build platform; build steps cannot
influence one another across runs. The L3 cache-poisoning prohibition — a
release build must not consume a shared cache that isn't re-verified on use — is
met per build type:

- **Go** — module cache re-verified against `go.sum` on load; module *and* build
  caches disabled on release (`cache: disabled`).
- **Python (pip)** — never opts into `setup-python`'s cache.
- **Python (uv)** — uv cache disabled on release builds (was the L2 gap, fixed
  in [#226](https://github.com/TomHennen/wrangle/pull/226)).
- **npm** — `setup-node` cache stays enabled; safe **only** because install is
  `npm ci`, which re-verifies each cached tarball against `package-lock.json`.
  **Gap:** replacing `npm ci` with `npm install` would break this — the L3
  verdict for npm is conditional on the install command.
- **pnpm** — `setup-node` cache disabled unconditionally (the pnpm store has no
  install-time re-verification).
- **Container** — BuildKit cache forced `disabled` on release; an allowlist gate
  fails the build on a bad `cache` value (no silent fallback); the PR cache key
  is sanitized before reaching the BuildKit config (blocks `,type=registry`
  injection).

Evidence: the build-job `cache` inputs in each `build_and_publish_*.yml` and the
`validate_inputs.sh` / `resolve_cache.sh` / `detect_tooling.sh` helpers under
[`build/actions/`](../build/actions/). Adapters/scan tools receive **no
secrets** (the orchestrator strips the environment); `GITHUB_TOKEN` is granted
only to the steps that publish.

### [Hosted](https://slsa.dev/spec/v1.2/build-requirements)
**Required for: SLSA Build Level 2+**
All jobs `runs-on: ubuntu-latest` (GitHub-hosted).

### [Ephemeral environment](https://slsa.dev/spec/v1.2/build-requirements)
**Required for: SLSA Build Level 3**
GitHub-hosted runners are provisioned fresh per job; build / attest / verify are
separate jobs → separate ephemeral VMs.

## Distribution

### [Provenance distribution](https://slsa.dev/spec/v1.2/build-track-basics)
**Required for: SLSA Build Level 1+**
Provenance reaches consumers via the GitHub attestation store
(`attestations: write`), and — for containers — as an OCI referrer on the image
digest (`push-to-registry: true`). A per-artifact signed VSA is delivered as a
release asset (file artifacts) or a registry referrer (containers).

**Gap (publish-before-verify, Go + Container):** these publish inline (goreleaser
/ `docker push`) *before* the `attest`/`verify` jobs run; a verification failure
fails the workflow conclusion but cannot un-publish. Consistent with SLSA's model
— the contract is *"the consumer runs the verifier,"* not *"an attestation
exists."* An artifact downloaded during the gap, or after a verify failure, has
no valid VSA and must be treated as untrusted.

## Maintaining this page

A living document: when a build type's mechanism changes, update the requirement
and its evidence in the same PR. The historical *why* behind each hardening step
stays in [`SLSA_L3_AUDIT.md`](SLSA_L3_AUDIT.md).
