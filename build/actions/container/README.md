# Wrangle Build Container

A GitHub composite action that builds and publishes a container image to GitHub Container Registry (ghcr.io), generates and extracts an SBOM, and (when wired into the reusable workflow) signs the image with Cosign and attaches SLSA provenance (Build L3).

> **Note:** This README documents *currently-shipped* behavior. For the full design — including Cosign signing, SLSA L3 provenance, the release gate, failure contract, and trust model — see [`SPEC.md`](./SPEC.md). The spec is forward-looking; features described there but not yet implemented in `action.yml` will land in follow-up PRs, and this README will be updated in the same commit. The full structure this README must eventually cover (quick-start example, verification commands, failure runbook) is defined in [`SPEC.md` §"Required contents of `build/actions/container/README.md`"](./SPEC.md#required-contents-of-buildactionscontainerreadmemd).

## Recommended companion: source scan

This action hardens *how* your container image is produced. It does NOT scan your source — vulnerable deps in your Dockerfile's base image or pinned packages, dangerous workflow triggers, or missing branch protection still slip through and would be faithfully L3-attested by wrangle as legitimately built. Pair this with wrangle's source-scan workflow ([`actions/scan/README.md`](../../../actions/scan/README.md)) to close that gap on every PR and push. Without it, an attacker who lands a malicious dep or workflow misconfiguration routes around the build-side hardening — the May 2026 Mini Shai-Hulud compromise of TanStack/router is the canonical recent example of why this matters.

## Build Track level

Consumed through wrangle's reusable workflow (`build_and_publish_container.yml`), the container build meets **SLSA v1.2 Build L3**. You do not need to reason about individual SLSA L3 requirements to use this — the single Build Track level is the claim. Two conditions narrow it:

- **Reusable consumption only.** Calling the `build/actions/container` composite directly from a workflow you author yourself forfeits the build-vs-sign job separation and is **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation the L3 verdict assumes.

Release builds run with the BuildKit `type=gha` cache disabled, so the attested image cannot be influenced by a shared, cross-build cache that BuildKit does not re-verify on cache hits (SLSA's "Isolated" requirement). PR builds default to an isolated, per-PR cache scope so one PR cannot poison another's cache entries. The full per-builder analysis is [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) (Finding 2).

## What this action does today

- Builds a Docker image from a Dockerfile at a caller-provided path
- Pushes the image to a container registry (ghcr.io supported; other registries are out of scope — see [`SPEC.md`](./SPEC.md#current-scope-ghcrio-only))
- Generates a BuildKit-native SBOM and attaches it to the image as an OCI attestation
- Extracts the SBOM in SPDX JSON format and uploads it as a workflow artifact
- Generates a step summary with the results

## Planned (per spec, not yet implemented)

- Cosign keyless signing of the pushed image digest
- SLSA L3 provenance via `slsa-github-generator` (the reusable workflow in `.github/workflows/build_and_publish_container.yml` is the entry point for this)
- SBOM vulnerability scanning with `osv-scanner` (non-blocking)
- The release gate job that enforces "image is signed AND attested before any downstream release job runs"

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

Release builds always run cache-free. BuildKit's `type=gha` cache is not re-verified on cache hits and is shared cross-build via GitHub's branch-scoped cache service, so an L3-attested release build must not consume it ([`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 2). That is not configurable — it is what keeps the container path at Build L3.

**PR / non-release builds** default to a per-PR isolated cache. They produce no attested artifact, so cache poisoning is not a SLSA L3 concern at that layer — but it is still a CI-hygiene concern. A malicious PR that obtains code execution in its build step (a poisoned `Dockerfile`, an exploited build-tool vulnerability) can write a poisoned entry to the GitHub Actions cache that a *later* PR build reads; the later build's "tests pass" and SBOM signals can then be quietly wrong. This is **PR-to-PR cache poisoning** — [Cacheract](https://adnanthekhan.com/2024/12/21/cacheract-the-monster-in-your-build-cache/) demonstrates poisoned entries surviving in the cache for the full eviction window.

The reusable workflow's `pr-cache` input tunes the PR-build cache, trading PR-build speed against this exposure. It never affects release builds — those are cache-free unconditionally.

| `pr-cache` | PR build behavior | When to use |
|------------|-------------------|-------------|
| `isolated` (default) | Each PR gets its own cache scope, keyed by the GitHub-assigned PR number; PR A cannot write entries PR B reads. Rebuilds within a PR still hit cache. | Safe default — closes PR-to-PR poisoning while keeping in-PR cache speedup. |
| `enabled` | Shares the cross-branch BuildKit cache. Fastest first-build off main's entries, but a malicious PR can poison entries that later PR builds read. | Trusted-contributor repos where PR authors are vetted *and* the first-build speedup matters more than isolation. |
| `read-only` | PR builds read the shared cache (fast first build off main's entries) but never write it, so a PR cannot poison it. | When you want shared-cache *reads* but no PR write path. |
| `disabled` | PR builds also run cache-free. Strictest, slowest. | Strict-isolation contexts (regulated, government), or repos that treat every PR as untrusted. |

The per-PR scope is keyed by `github.event.pull_request.number` — a GitHub-assigned, monotonically unique integer per PR. It is *not* keyed by branch name, so two PRs that happen to share a source branch name (e.g. both `patch-1` from different forks) get distinct cache scopes. On non-PR events (push, workflow_dispatch) the scope falls back to the ref name.

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_container.yml@v0.2.0
with:
  path: .
  imagename: ghcr.io/<owner>/<repo>
  registry: ghcr.io
  # pr-cache: isolated   # this is the default; shown here for clarity
```

> **Never invoke this workflow from a `pull_request_target` trigger.** Such workflows run in the base-repo context with base-repo cache *write* access, which makes a fork PR the highest-risk cache-poisoning vector. Wrangle's reusable workflows refuse `pull_request_target` ([#202](https://github.com/TomHennen/wrangle/issues/202)); do not work around that refusal.

## SLSA attestation verification (default-on, opt-out)

After the SLSA generator emits the provenance attestation, wrangle's reusable workflow runs `cosign verify-attestation --type slsaprovenance` against the just-pushed image digest before declaring the workflow successful. This catches the "registry served bytes that don't match what wrangle pushed" attack window. If verification fails, the workflow fails — and any downstream release-time job that depends on it via `needs:` is blocked.

Wrangle pins the cert identity to the SLSA generator's tag (`v2.1.0` today) so verification only succeeds against attestations signed by *that* generator workflow. The `--certificate-github-workflow-repository` claim is additionally pinned to your repository, so attestations minted from another repo using the same generator version do not pass.

To opt out (e.g., you maintain a custom verification flow), pass `verify-image: false`:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_container.yml@v0.2.0
with:
  path: .
  imagename: ghcr.io/<owner>/<repo>
  registry: ghcr.io
  verify-image: false   # skip wrangle's verification; you handle it
```

### Private-repo limitation

`cosign verify-attestation` against ghcr.io public images works without registry authentication. For **private** images (or registries with anonymous-pull disabled), the manifest and attestation pulls require auth that wrangle's verify job doesn't currently provide — so private-repo adopters must set `verify-image: false` and verify in their own job today. If this affects you, please comment or thumbs-up [#182](https://github.com/TomHennen/wrangle/issues/182) so we can prioritize.

### Future: image-signature verification

When `cosign sign` of the image digest lands in the composite action, this verify job will additionally check the image signature with the adopter's `workflow_ref` as the cert identity.

## SBOM

The action generates an SBOM for the container it builds. Today the SBOM is available two ways:

- As a workflow artifact named `container-metadata-<shortname>`, downloadable from the Actions run page or via `actions/download-artifact` in a downstream job. The artifact is the zip of `metadata/container/<shortname>/`'s contents — downloading it extracts the metadata files at the top level of whatever `path:` you choose, not nested under `metadata/container/<shortname>/`. The reusable workflow exposes the artifact name as the `metadata-artifact-name` output so callers don't have to hardcode it.
- Embedded in the OCI image manifest as a BuildKit attestation, retrievable from the image itself with `docker buildx imagetools inspect --format '{{ json .SBOM.SPDX }}' <image>@<digest>`

See [`SPEC.md` §"Where to find the SBOM"](./SPEC.md#where-to-find-the-sbom) for the full publication story (including the planned cosign SBOM attestation).

## Container vulnerability scanning

Per the failure contract in [`SPEC.md`](./SPEC.md#failure-contract), SBOM vulnerability scanning is **non-blocking**: findings are uploaded as SARIF and visible in the Security tab, but they do not fail the build. This is a deliberate design choice — vulnerability triage is a policy decision adopters own, and hard-blocking can itself become a release blocker when a fix needs to ship despite an unavoidable upstream CVE. See the spec for the full rationale.

![Wrangle Build Container Summary showing vulns found by OSV](/assets/images/osv_sbom_summary.png)

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification
- [`../../../docs/SPEC.md`](../../../docs/SPEC.md) — wrangle's overall architecture and build-type model
- [`../../README.md`](../../README.md) — the build/ directory overview
- [`../../../actions/scan/README.md`](../../../actions/scan/README.md) — recommended source-scan companion
