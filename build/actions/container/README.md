# Wrangle Build Container

Build and publish a container image to ghcr.io with an SBOM, Cosign signature, and SLSA L3 provenance.

## Quick-start

```yaml
jobs:
  build:
    permissions:
      contents: write   # SLSA generator's upload-assets job
      id-token: write   # OIDC for Sigstore signing
      packages: write   # push to ghcr.io
      actions: read
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_container.yml@v0.2.0
    with:
      path: .
      imagename: ghcr.io/<owner>/<repo>
      registry: ghcr.io
```

Pair with [`check_source_change.yml`](../../../actions/scan/README.md) — build hardens *how*, source scan covers *what was committed*.

For the full design (failure contract, trust model, planned signing/provenance steps in the composite), see [`SPEC.md`](./SPEC.md). This README only describes shipped behavior.

## Build Track level

Consumed through `build_and_publish_container.yml`, the container build meets **SLSA v1.2 Build L3**. Two conditions narrow the claim:

- **Reusable consumption only.** Calling the composite from your own workflow forfeits the build-vs-sign job separation and is **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation L3 assumes.

Release builds run with the BuildKit `type=gha` cache disabled (BuildKit doesn't re-verify cache hits, so a shared cache violates SLSA's "Isolated" requirement). PR builds default to a per-PR isolated cache. Full analysis: [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 2.

## What this action does

- Builds a Docker image from a caller-provided Dockerfile path.
- Pushes to ghcr.io (other registries out of scope — see [`SPEC.md`](./SPEC.md#current-scope-ghcrio-only)).
- Generates a BuildKit-native SBOM, attaches it to the image as an OCI attestation, and uploads it as a workflow artifact in SPDX JSON.

The reusable workflow `build_and_publish_container.yml` adds `slsa-github-generator` for L3 provenance, `cosign verify-attestation` of that provenance against the just-pushed digest, and the release-gate job. Still planned (not yet wired into either layer): Cosign keyless signing of the image digest itself and OSV-Scanner against the SBOM (non-blocking) — see [`SPEC.md`](./SPEC.md).

## Controlling when provenance is generated

The reusable workflow's `release-events` input controls which events trigger SLSA provenance generation. Default: `non-pull-request`. Other shorthands: `tag-only`, `main-and-tags`. A comma-separated `github.event_name` list is also accepted. See [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating" for the full vocabulary.

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_container.yml@v0.2.0
with:
  path: .
  imagename: ghcr.io/<owner>/<repo>
  registry: ghcr.io
  release-events: tag-only   # only tag pushes mint provenance
```

Note: `release-events` currently scopes the SLSA provenance and verify jobs. The docker push happens mid-composite and is gated by your workflow's own trigger configuration (see [`SPEC.md` §"Trigger restriction"](./SPEC.md#trigger-restriction)).

## Controlling the PR build cache

Release builds always run cache-free — BuildKit's `type=gha` cache isn't re-verified on hits and is shared cross-build, which would violate SLSA's "Isolated" requirement ([`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 2). Not configurable.

**PR builds** default to a per-PR isolated cache. PR builds produce no attested artifact, so cache poisoning isn't an L3 concern at that layer — but it's still a CI-hygiene concern: a malicious PR with code execution can poison cache entries a *later* PR reads, silently corrupting that build's "tests pass" and SBOM signals ([Cacheract](https://adnanthekhan.com/2024/12/21/cacheract-the-monster-in-your-build-cache/)). The `pr-cache` input tunes the trade-off:

| `pr-cache` | PR build behavior | When to use |
|------------|-------------------|-------------|
| `isolated` (default) | Per-PR cache scope, keyed by PR number. PR A cannot write entries PR B reads; rebuilds within a PR still hit cache. | Safe default — closes PR-to-PR poisoning, keeps in-PR speedup. |
| `enabled` | Shares the cross-branch cache. Fastest first build, but a malicious PR can poison later PR builds. | Trusted-contributor repos. |
| `read-only` | PR builds read the shared cache but never write it. | Shared-cache reads, no PR write path. |
| `disabled` | PR builds also run cache-free. | Strict-isolation contexts. |

The scope is keyed by `github.event.pull_request.number` (a GitHub-assigned unique integer), not branch name — two PRs sharing a branch name from different forks get distinct scopes. On non-PR events the scope falls back to the ref name.

> **Never invoke this workflow from `pull_request_target`.** That trigger runs in the base-repo context with cache write access, making a fork PR the highest-risk poisoning vector. Wrangle's reusable workflows refuse it ([#202](https://github.com/TomHennen/wrangle/issues/202)).

## SLSA attestation verification (default-on, opt-out)

The reusable workflow runs `cosign verify-attestation --type slsaprovenance` against the just-pushed image digest before declaring success. This catches the "registry served different bytes than wrangle pushed" attack window — failure blocks any downstream `needs:` job. The cert identity is pinned to the SLSA generator's tag (`v2.1.0` today) and to your repository, so attestations from a different generator version or a different repo do not pass.

To opt out (custom verification flow):

```yaml
with:
  verify-image: false
```

**Private-repo limitation.** Verify currently does no registry auth, so private-repo adopters must set `verify-image: false` and verify in their own job. See [#182](https://github.com/TomHennen/wrangle/issues/182). When `cosign sign` of the image digest lands, this verify job will additionally check the image signature against the caller's `workflow_ref`.

## SBOM

Generated for every build. Available two ways:

- **Workflow artifact** `container-metadata-<shortname>` — exposed via the workflow's `metadata-artifact-name` output. Download with `actions/download-artifact`; the metadata files land at the top level of whatever `path:` you choose (the `metadata/container/<shortname>/` prefix is a workspace convention, not preserved in the zip).
- **OCI image attestation** — `docker buildx imagetools inspect --format '{{ json .SBOM.SPDX }}' <image>@<digest>`.

OSV-Scanner against the SBOM is planned (non-blocking — vulnerability triage is a policy decision adopters own); the failure contract in [`SPEC.md`](./SPEC.md#failure-contract) describes the eventual behavior.

![Wrangle Build Container Summary showing vulns found by OSV](/assets/images/osv_sbom_summary.png)

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification.
- [`../../../docs/SPEC.md`](../../../docs/SPEC.md) — wrangle's architecture.
- [`../../../actions/scan/README.md`](../../../actions/scan/README.md) — source-scan companion.
