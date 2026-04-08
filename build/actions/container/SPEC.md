# Container Build Action — Specification

## Overview

The container build action builds a Docker image, generates and scans an SBOM, publishes the image, signs it, and produces SLSA L3 provenance. It implements the build stage failure contract from `docs/SPEC.md` for container artifacts.

Two components work together:

| Component | Location | Scope |
|-----------|----------|-------|
| **Composite action** | `build/actions/container/action.yml` | Build, SBOM, publish, sign |
| **Reusable workflow** | `.github/workflows/build_and_publish_container.yml` | Orchestrates composite action + SLSA L3 provenance + gate |

The split exists because SLSA L3 provenance via `slsa-github-generator` requires a reusable workflow — it cannot run inside a composite action.

## Inputs and outputs

### Composite action inputs

| Input | Required | Description |
|-------|----------|-------------|
| `path` | yes | Relative path to the directory containing the Dockerfile |
| `imagename` | yes | Full image name including registry (e.g., `ghcr.io/owner/repo/image`) |
| `registry` | yes | Container registry hostname (e.g., `ghcr.io`) |
| `github_token` | yes | `GITHUB_TOKEN` with `packages:write` scope |

### Composite action outputs

| Output | Description |
|--------|-------------|
| `digest` | Image digest (`sha256:...`) |
| `imagename` | Normalized (lowercased) image name |
| `sbom` | Path to the extracted SBOM (SPDX JSON) |

### Reusable workflow inputs

| Input | Required | Description |
|-------|----------|-------------|
| `path` | yes | Passed through to composite action |
| `imagename` | yes | Passed through to composite action |
| `registry` | yes | Passed through to composite action |
| `publish_provenance_for_private_repo` | no | Opt-in to post provenance to public Rekor for private repos (default: `false`) |

### Reusable workflow secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `gh_token` | yes | GitHub token, forwarded to both composite action and SLSA generator |

## Step sequence

The composite action executes these steps in order:

```
1. Validate and normalize inputs
2. Checkout source
3. Set up Docker Buildx
4. Extract metadata (tags, labels)
5. Log in to container registry
6. Build and push image (with BuildKit SBOM + provenance)
7. Prepare metadata directory
8. Extract SBOM from built image
9. Scan SBOM for vulnerabilities (osv-scanner)
10. Install Cosign
11. Sign image (keyless, with retry)
12. Generate step summary
13. Upload metadata artifact
```

SBOM extraction and scanning happen before signing. This way, if the SBOM can't be generated, the pipeline stops before signing an image we can't verify the contents of.

The reusable workflow then adds:

```
14. Generate SLSA L3 provenance (slsa-github-generator)
15. Gate job — verify both build+sign and provenance succeeded
```

## Input validation

All inputs are passed through `env:` blocks — never interpolated directly in `run:` blocks (prevents expression injection).

| Input | Validation |
|-------|-----------|
| `path` | Must be relative (no leading `/`), no `..` traversal, characters match `^[a-zA-Z0-9_./-]+$` |
| `registry` | Characters match `^[a-z0-9.-]+$` |
| `imagename` | Characters match `^[a-z0-9./:_-]+$` |

Globbing is disabled (`set -f`) before processing any external input.

## Failure contract

Implements the build stage failure contract from `docs/SPEC.md`:

| Step | On failure | Rationale |
|------|-----------|-----------|
| Build | **Pipeline stops** | Nothing to publish |
| SBOM generation | **Pipeline stops** | Can't verify artifact contents without an SBOM |
| SBOM vulnerability scan | **Continue** (non-blocking) | Transitive dependency vulns are informational. Findings are uploaded as SARIF. Blocking creates alert fatigue on issues maintainers often can't act on. |
| Cosign signing | **Pipeline stops** | An unsigned image is indistinguishable from a compromised one. Publishing it trains consumers to accept unsigned images — the exact condition an attacker needs. |
| SLSA provenance | **Pipeline stops** | If consumers expect provenance and it's missing, that's either an attack or a broken release. Neither should ship. |

### Error messages on security-critical failures

When signing or provenance fails, the error message must tell the action adopter what happened and what to do. Generic "step failed" output is not sufficient — adopters need to know the image is unsafe to release and that re-running the workflow is the correct remediation.

| Failure | Error message |
|---------|--------------|
| Cosign signing (retries exhausted) | `wrangle: FATAL: Cosign signing failed after N attempts. The image was pushed but is NOT signed and MUST NOT be released. Re-run this workflow to retry.` |
| SLSA provenance | `wrangle: FATAL: SLSA provenance generation failed. The image has no provenance and MUST NOT be released. Re-run this workflow to retry.` |

The Cosign error is emitted directly by the signing step in the composite action. The SLSA provenance error is emitted by the **gate job** in the reusable workflow, since the provenance step runs inside `slsa-github-generator`'s reusable workflow and wrangle does not control its error output.

## Cosign image signing

The image is signed using Cosign keyless signing (Sigstore OIDC). This is distinct from the SLSA provenance attestation — they answer different questions:

| | Cosign image signature | SLSA provenance attestation |
|---|---|---|
| What it signs | The image digest directly | An in-toto attestation about how the image was built |
| What it proves | "This image was produced by a trusted GitHub Actions identity" | "This image was built from commit X in repo Y by builder Z" |
| How consumers verify | `cosign verify` | `slsa-verifier verify-image` or `cosign verify-attestation` |
| Ecosystem use | Kubernetes admission controllers (Kyverno, Sigstore policy-controller), registry policies | Policy engines (Ampel, in-toto), audit trails |

Both are needed. Cosign signatures are the access-control layer (many orgs cannot deploy unsigned images). SLSA provenance is the audit/trust layer (rich metadata for policy decisions).

### Signing details

- **Method:** Keyless via Sigstore OIDC (`cosign sign --yes`)
- **Identity:** The GitHub Actions workflow's OIDC token (tied to repo, workflow, and ref)
- **What is signed:** The image by digest (`${image}@${digest}`)
- **Transparency log:** Entry recorded in Rekor (`rekor.sigstore.dev`)

### Retry strategy for Sigstore outages

Sigstore/Fulcio may experience transient outages. Per the spec: "the correct response is to wait and retry, not to ship without signing."

- **Attempts:** 5
- **Backoff:** Exponential with jitter — 10s, 20s, 40s, 80s, 160s (base), plus random 0-5s jitter
- **On exhaustion:** Step fails, pipeline stops. The image has been pushed but is unsigned, so the gate job prevents downstream consumption.
- **No fallback:** There is no weaker signing method to fall back to. If Sigstore is down, the release waits.

## SBOM generation and scanning

### Generation

BuildKit generates the SBOM natively during `docker build` (`sbom: true` in build-push-action). The SBOM is extracted post-push via `docker buildx imagetools inspect` in SPDX JSON format.

### Vulnerability scanning

The extracted SBOM is scanned using `osv-scanner` for known vulnerabilities.

SBOM vulnerability scanning uses the shared scanning infrastructure defined in `docs/SPEC.md` ("Shared SBOM vulnerability scanning"). The container-specific detail is only how the SBOM is generated and extracted (see above). Scanning behavior — tool, output format, non-blocking policy — is the same across all build types.

## SLSA L3 provenance

Provenance is generated by `slsa-framework/slsa-github-generator`'s `generator_container_slsa3.yml` reusable workflow (currently pinned at v2.1.0).

### What it produces

- An in-toto attestation with SLSA provenance predicate (v0.2), signed via Sigstore keyless signing
- The attestation is pushed to the container registry as a cosign attestation attached to the image digest
- A transparency log entry in Rekor

### Why it must be a separate job

The SLSA generator is a reusable workflow, not an action. It must run as a separate `uses:` job in the caller workflow. This is a security property — the generator controls its own execution environment, which is what enables the L3 "hardened build platform" guarantee.

### Trigger restriction

Provenance is only generated on non-PR events (`if: ${{ ! startsWith(github.event_name, 'pull_') }}`). The SLSA generator does not support `pull_request` triggers. This is acceptable because PRs don't publish artifacts.

### Private repos

Private repo names are posted to the public Rekor transparency log. The `publish_provenance_for_private_repo` input must be explicitly set to `true` to opt in.

## Gate job

The reusable workflow includes a gate job that requires both the build job (including Cosign signing) and the provenance job to succeed. This enforces the hard-fail contract:

- If Cosign signing fails → build job fails → gate fails → workflow fails
- If SLSA provenance fails → provenance job fails → gate fails → workflow fails
- If both succeed → gate passes → workflow succeeds

The gate job is the single point that downstream consumers (deployment workflows, release tags) should depend on.

## Permissions

### Composite action (inherited from calling workflow)

| Permission | Scope | Why |
|------------|-------|-----|
| `contents` | `read` | Checkout source |
| `packages` | `write` | Push image to registry, attach Cosign signature |
| `id-token` | `write` | Keyless Cosign signing via Sigstore OIDC |

### Provenance job (in reusable workflow)

| Permission | Scope | Why |
|------------|-------|-----|
| `actions` | `read` | Detect GitHub Actions environment |
| `id-token` | `write` | OIDC token for Sigstore signing of provenance attestation |
| `packages` | `write` | Upload provenance attestation to registry |

## BuildKit-native provenance vs SLSA L3

The `docker/build-push-action` with `provenance: mode=max` produces BuildKit-native provenance (in-toto attestation embedded in the OCI manifest). This is ecosystem-level provenance — useful but not cryptographically signed by a trusted third party.

SLSA L3 provenance via `slsa-github-generator` is a stronger guarantee: it's produced by an isolated builder that controls its own signing keys via Sigstore OIDC, and it's independently verifiable via `slsa-verifier`. Both are generated; they are complementary, not redundant.

## Trust model and roles

Three distinct roles interact with the container build pipeline:

| Role | Who | Relationship to wrangle |
|------|-----|------------------------|
| **Wrangle maintainers** | Maintainers of the wrangle project | Provide the action and workflow |
| **Action adopters** | Project maintainers who add wrangle's workflow to their repo | Configure and run the pipeline |
| **Image consumers** | Ops/platform teams or end users who pull and deploy images | Verify and run the output |

These roles are often different people in different organizations. An action adopter cannot control how consumers deploy images, and consumers may not know which CI system produced an image.

### What wrangle guarantees

**To action adopters:** If the workflow succeeds, the image is signed with Cosign and has SLSA L3 provenance. If it fails, no success signal is emitted — the image should not be treated as a release. Wrangle handles the signing and attestation automatically; adopters don't need to understand Cosign or SLSA to produce verifiable artifacts.

When signing or provenance fails, wrangle emits a clear error message telling the adopter the image is not safe to release and to re-run the workflow (see "Error messages on security-critical failures" above).

**To image consumers (via adopters):** A successful wrangle build produces an image with two independently verifiable properties:
1. A **Cosign signature** — proves the image was produced by a specific GitHub Actions workflow in a specific repo
2. A **SLSA L3 provenance attestation** — proves what source code, builder, and build steps produced the image

These enable consumers to enforce verification policies on their side, but wrangle cannot enforce that consumers actually check.

### Guidance for action adopters

Adopters should communicate their signing/provenance story to their consumers:
- Document that images are signed and how to verify them (`cosign verify`, `slsa-verifier verify-image`)
- Publish the expected signing identity (the GitHub Actions OIDC identity for their repo/workflow)
- Note that unsigned images from failed workflows may exist in the registry and should not be used

### Image pushed before signed

Container registries require the image to exist before a signature can be attached. If signing fails after push, the image is in the registry but unsigned. This is an inherent constraint of OCI registries, not a design flaw:

- The **workflow fails**, and the error message tells the adopter not to release the image
- Adopters should not tag releases from failed workflows
- Consumers who enforce Cosign verification (via Kyverno, Sigstore policy-controller, or manual `cosign verify`) will reject the unsigned image automatically
- The unsigned image is not deleted because `packages:delete` permission introduces its own risks and most callers won't grant it

The protection is defense in depth: wrangle ensures signed images are the only *successful* output, and consumer-side admission control ensures unsigned images are never *accepted*.

## Re-run behavior

Re-running the workflow after a signing or provenance failure rebuilds and re-pushes the image (producing a new digest). The signing and provenance steps then operate on the new digest, so the result is fully consistent. Adopters can safely re-run failed workflows without worrying about stale digests or mismatched attestations.

## Known limitations

- **Multi-platform builds.** The action uses Buildx, which supports multi-platform builds, but this has not been tested. Multi-platform support is not currently specified or guaranteed.
- **SLSA provenance predicate version.** The generator currently produces predicate v0.2. The SLSA spec has moved to v1.0. Monitor `slsa-github-generator` for updates.
- **`packages:write` always required for provenance.** Even for non-ghcr.io registries, due to GitHub Actions token handling (tracked upstream in slsa-github-generator#1257).
