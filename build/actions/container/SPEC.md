# Container Build Action — Specification

## Overview

The container build action builds a Docker image, generates and scans an SBOM, publishes the image, signs it, and produces SLSA L3 provenance. It implements the build stage failure contract from `docs/SPEC.md` for container artifacts.

Two components work together:

| Component | Location | Scope |
|-----------|----------|-------|
| **Composite action** | `build/actions/container/action.yml` | Build, SBOM, publish, sign |
| **Reusable workflow** | `.github/workflows/build_and_publish_container.yml` | Orchestrates composite action + SLSA L3 provenance + gate |

The split exists because SLSA L3 provenance via `slsa-github-generator` requires a reusable workflow — it cannot run inside a composite action.

### Current scope: ghcr.io only

This spec and the current implementation are scoped to **GitHub Container Registry (`ghcr.io`)**. The `registry` input accepts any hostname and `docker/login-action` will technically log in anywhere, but the permissions model, SLSA provenance wiring, and trust assumptions are all tailored to ghcr.io today. Pushing to Docker Hub, ECR, GAR, Harbor, or any other OCI registry is **not supported** right now — treat it as out of scope, not just untested.

Multi-registry support is a planned extension. See "Known limitations" for the specific gaps that would need to close before other registries are supported.

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
| `digest` | The image digest returned by the registry after `docker push` (`sha256:...`). This is the canonical identifier for the signed and attested image — tags are mutable, digests are not. |
| `imagename` | The validated image name, lowercased (OCI image names must be lowercase). Matches the `imagename` input except for case. |
| `sbom` | Workspace-relative path of the SPDX JSON SBOM extracted from the built image via `docker buildx imagetools inspect`. Written under `./metadata/container/<shortname>/sbom.spdx.json`. |

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

### Reusable workflow outputs

The reusable workflow surfaces the identifiers a downstream release job needs to act on the just-built image. Each output is only meaningful if the gate job passed — consumers must depend on the reusable workflow completing successfully, not read these outputs from a failed run.

| Output | Description |
|--------|-------------|
| `digest` | The image digest of the published image (`sha256:...`), forwarded from the composite action's build-and-push step. Identifies the exact image that was signed and attested. |
| `imagename` | Validated, lowercased image name (e.g., `ghcr.io/owner/repo/image`), forwarded from the composite action. |
| `sbom_artifact` | Name of the uploaded workflow artifact containing the SPDX SBOM and SARIF scan output (e.g., `container-build-results-<shortname>`). Downstream jobs can fetch it via `actions/download-artifact`. |

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

Cosign signing lives inside the **composite action** (step 11), not the reusable workflow. It has to run on the same runner that pushed the image: the BuildKit daemon state, registry credentials, and the workflow's OIDC token environment are already set up there, and the signing identity wrangle wants is the *calling workflow's* GitHub Actions OIDC identity — not a wrangle-internal identity. Moving signing into the reusable workflow would either break that identity binding or require re-establishing all of the push-time state in a fresh job. See "Signing details" for the exact identity and what it covers.

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
| Build | **Pipeline stops** | Nothing to publish. |
| SBOM generation | **Pipeline stops** | Can't verify artifact contents without an SBOM. |
| SBOM vulnerability scan | **Continue** (non-blocking) | Transitive dependency vulns are informational. Findings are uploaded as SARIF. Blocking creates alert fatigue on issues maintainers often can't act on, and it can itself become a *release blocker*: maintainers sometimes need to ship an image with one known, unavoidable vulnerability in order to publish the fix for a different one, or to accept an upstream CVE that has no patched version yet. A hard-block on scan findings would prevent that. Vulnerability triage is a policy decision the adopter owns, not something wrangle should preempt. |
| Cosign signing | **Pipeline stops**; image already pushed | The image has already been pushed to the registry by the time signing runs (OCI registries require the blob to exist before a signature can be attached — see "Image pushed before signed"). Failing the pipeline is wrangle's signal that the image must not be treated as a release: it emits the fatal error message, fails the gate job, and blocks any downstream job that depends on the reusable workflow completing. Adopters are instructed not to tag or promote failed builds. Consumers who verify signatures (Kyverno, Sigstore policy-controller, manual `cosign verify`) will reject the unsigned image. The maintainer's remediation is to re-run the workflow, producing a new digest that can be signed cleanly. |
| SLSA provenance | **Pipeline stops**; image already pushed | Same shape as Cosign: the image has shipped to the registry, but wrangle's notion of a *successful release* requires provenance. Failing the gate tells adopters not to promote the image, and the error message instructs them to re-run. Consumers enforcing provenance via `slsa-verifier` will reject the un-attested image. As with signing, the image being physically present in the registry isn't the problem — an unsigned/un-attested image has effectively not shipped under wrangle's contract as long as consumers enforce verification. |

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

- **Pipeline location:** Step 11 of the composite action, immediately after SBOM vulnerability scanning and before the metadata-artifact upload. Runs on the same runner as the push, not in a separate job or the reusable workflow (see "Step sequence" for why).
- **Method:** Keyless via Sigstore OIDC (`cosign sign --yes`).
- **Identity:** The **calling workflow's** GitHub Actions OIDC token — i.e., the adopter's workflow, not any wrangle-internal identity. The resulting Fulcio certificate's subject is `https://github.com/<adopter-org>/<adopter-repo>/.github/workflows/<caller-workflow>.yml@<ref>`, so consumers can (and should) pin verification to a specific adopter repo, workflow file, and ref pattern. Wrangle's only role is transporting the OIDC token into the `cosign sign` invocation — it never handles a static signing key.
- **What is signed:** The image by digest (`${image}@${digest}`), never by tag. Signing by digest means a post-push tag swap can't be laundered into a matching signature.
- **Transparency log:** Entry recorded in Rekor (`rekor.sigstore.dev`).

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

- An in-toto attestation carrying a SLSA provenance predicate, signed via Sigstore keyless signing
- The attestation is pushed to the container registry as a cosign attestation attached to the image digest
- A transparency log entry in Rekor

### Predicate version

As of `slsa-github-generator` v2.1.0 (the version wrangle currently pins), the container generator emits `predicateType: https://slsa.dev/provenance/v0.2`. The SLSA Provenance spec has since published v1.0, and some ecosystem tooling — notably `actions/attest-build-provenance` — produces `slsa.dev/provenance/v1` today. However, v1.0 support in the **container** builder of `slsa-github-generator` has not shipped; it's tracked upstream in [`slsa-framework/slsa-github-generator#1524`](https://github.com/slsa-framework/slsa-github-generator/issues/1524).

Wrangle intentionally stays on `slsa-github-generator` (rather than switching to `actions/attest-build-provenance`) because that generator is what produces SLSA **L3** for containers — the "hardened build platform" property, which requires an isolated reusable-workflow builder. `actions/attest-build-provenance` produces v1 predicates but not the L3 isolation guarantee, so it isn't a drop-in replacement here.

The plan:

- Wait for upstream to ship v1.0 from the container generator.
- Bump the pinned `slsa-github-generator` version in the same commit as any checksum update.
- No wrangle-side contract changes should be required, since consumers already discriminate attestations by `predicateType` and both `v0.2` and `v1` predicates are valid for the same subject digest.

### Why it must be a separate job

The SLSA generator is a reusable workflow, not an action. It must run as a separate `uses:` job in the caller workflow. This is a security property — the generator controls its own execution environment, which is what enables the L3 "hardened build platform" guarantee.

### Trigger restriction

Neither Cosign signing nor SLSA provenance runs on `pull_request` triggers. Both are gated on `if: ${{ ! startsWith(github.event_name, 'pull_') }}`. This is a deliberate design rule, not just a workaround for an upstream limitation:

- **PRs must not produce artifacts that look production-ready.** A Cosign-signed image from a PR branch is binary-indistinguishable from a signed release image at the consumer's verification step, and its signing identity would be tied to the PR branch (or worse, a fork) rather than the release branch. Consumers whose verification policy accepts "any signature from this repo" would treat a PR-built image as a release — exactly the shape of a release-confusion supply chain attack. The safe default is that PR builds *cannot* produce a signed or attested image, period.
- **SBOM generation and vulnerability scanning do run on PRs.** Those steps surface actionable information to the PR author (new CVEs, new dependencies pulled in by the change) without producing anything a consumer could mistake for a release. SBOM scan findings are uploaded as SARIF so they appear on the PR's Security tab.
- **SLSA provenance is additionally blocked by upstream.** `slsa-github-generator`'s container reusable workflow does not support `pull_request` events, so even if wrangle wanted to produce provenance on PRs, it couldn't. But wrangle would skip it on PRs regardless, for the same reason signing is skipped.

In practice a PR-triggered run executes: validate → build → push → SBOM extract → SBOM scan, and then exits without invoking signing, provenance, or the release gate. The gate job's success condition encodes the full release contract (build + SBOM + sign + provenance), which is only achievable on non-PR events — so PR runs never produce a successful gate, and adopters should not configure release tagging or deployment workflows to react to PR-triggered container builds.

### Private repos

Private repo names are posted to the public Rekor transparency log. The `publish_provenance_for_private_repo` input must be explicitly set to `true` to opt in.

## Gate job

The reusable workflow includes a gate job that requires both the build job (including Cosign signing) and the SLSA provenance job to succeed. This enforces the hard-fail contract:

- If Cosign signing fails → build job fails → gate fails → workflow fails
- If SLSA provenance fails → provenance job fails → gate fails → workflow fails
- If both succeed → gate passes → workflow succeeds

The gate job is the single point that downstream consumers (deployment workflows, release tags) should depend on. Consumers that depend on individual upstream jobs rather than the gate can race with a late failure and treat an unsigned or un-attested image as released — so always depend on the reusable workflow's completion, not on its internal job names.

### What happens when the gate fails

When the gate job fails, the reusable workflow as a whole fails with a non-zero conclusion. Concretely:

- **Downstream jobs don't run.** Any job in the calling workflow that declares `needs:` on the reusable workflow — typically release tagging, deployment, image promotion to a `:stable` tag, or GitHub Release creation — is skipped by GitHub Actions. This is the primary protection against adopters accidentally releasing a failed build.
- **The fatal error message is emitted.** The failing step (for Cosign: the signing step inside the composite action; for SLSA provenance: the gate job itself, since wrangle doesn't control the SLSA generator's error output) writes the wrangle error message from the "Error messages on security-critical failures" table. The adopter sees a clear instruction to re-run the workflow, not a generic "job failed."
- **The image is already in the registry.** Image push happens before signing (see "Image pushed before signed"), so when the gate fails, a pushed-but-unsigned or pushed-but-un-attested image exists at the computed digest. Wrangle's contract is that this image **must not be treated as a release**: no release tag, no deployment, no promotion. The defense is layered — the gate blocks downstream jobs, the error message blocks adopters, and consumer-side verification (`cosign verify` / `slsa-verifier`) blocks end users even if the first two layers are bypassed.
- **No auto-rollback, no auto-delete.** Wrangle does not attempt to delete the unsigned image from the registry. `packages: delete` is a broader permission than most callers will grant, and a failed delete (e.g., if the registry is the reason signing failed) would turn a recoverable failure into an unrecoverable one. The image stays in the registry; re-running the workflow produces a new digest.
- **Re-run is the remediation.** Adopters re-run the workflow; a new build produces a new digest, and signing and provenance are attempted fresh against that digest. See "Re-run behavior".

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

**To image consumers (via adopters):** A successful wrangle build produces an image with three independently verifiable properties:
1. A **Cosign signature** — proves the image was produced by a specific GitHub Actions workflow in a specific repo
2. A **SLSA L3 provenance attestation** — proves what source code, builder, and build steps produced the image
3. An **SPDX SBOM** — enumerates the image's contents (packages, versions, licenses), giving consumers a starting point for ongoing vulnerability management: tracking newly disclosed CVEs against an already-deployed image, inventorying transitive dependencies, feeding a VEX workflow, or answering "is this image affected by CVE-X?" after the fact

These enable consumers to enforce verification policies on their side, but wrangle cannot enforce that consumers actually check.

### Where to find the SBOM

Today the SPDX SBOM is published in two places, and a third is planned:

1. **Workflow artifact (available now).** The composite action uploads the `./metadata/` directory as the workflow artifact `container-build-results-<shortname>`, which contains the SBOM at `metadata/container/<shortname>/sbom.spdx.json` alongside SARIF scan output. Downstream jobs can fetch it with `actions/download-artifact`; humans can download it from the Actions run page. The reusable workflow exposes the artifact name as the `sbom_artifact` output so callers don't have to hardcode the naming convention.
2. **Embedded in the BuildKit image attestation (available now).** Because the build step is invoked with `sbom: true`, BuildKit attaches the SBOM to the OCI image manifest as an in-toto attestation. Consumers can retrieve it from the image itself, without access to the original workflow run, via:
   ```bash
   docker buildx imagetools inspect --format '{{ json .SBOM.SPDX }}' \
     ghcr.io/<owner>/<repo>/<image>@sha256:<digest>
   ```
3. **Cosign SBOM attestation (planned, not yet implemented).** A future release will additionally attach the SBOM to the signed image digest as `cosign attest --type spdxjson`, so that verified consumers can fetch it with `cosign download attestation` and be sure it's tied to the same digest the signature covers. See "Known limitations".

Adopters documenting their security story to consumers should pick (2) as the canonical source today — it's the easiest to retrieve from just an image reference, and doesn't depend on the workflow artifact still existing (GitHub retains workflow artifacts for a limited window).

### Guidance for action adopters

Adopters should communicate their signing/provenance story to their consumers:
- Document that images are signed and how to verify them (full example commands below)
- Publish the expected signing identity (the GitHub Actions OIDC identity for their repo/workflow)
- Note that unsigned images from failed workflows may exist in the registry and should not be used

#### Verification examples

Throughout this section, assume the example image is `ghcr.io/acme/svc@sha256:abc123...`, published from `github.com/acme/svc` by the workflow `.github/workflows/release.yml` on refs matching `refs/tags/v*`. Adopters should replace these values with their own repo, workflow filename, and ref pattern, then publish the resulting commands to their consumers.

**Verify the Cosign image signature.** The OIDC issuer is always `https://token.actions.githubusercontent.com` for GitHub Actions keyless signing; the certificate identity regexp is how consumers pin the signature to a specific adopter repo/workflow/ref pattern and reject everything else (including signatures from forks, from PR branches, or from unrelated workflows in the same repo):

```bash
cosign verify \
  --certificate-identity-regexp '^https://github\.com/acme/svc/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/acme/svc@sha256:abc123...
```

Notes on the flags:

- `--certificate-identity-regexp` anchors on `^` and terminates at `@refs/tags/v`. Anchoring on `^` prevents `https://github.com/evil/acme-svc/...` from matching as a suffix; terminating on the ref pattern rejects signatures produced from branches or PRs. For stricter production policy, pin the exact ref (`--certificate-identity` with the full `@refs/tags/v1.2.3`), not a regex.
- `--certificate-oidc-issuer` must be set explicitly; omitting it allows *any* Sigstore-issued certificate, which defeats the identity binding.
- Verify by digest, never by tag. A tag-based verify races with tag mutation.

**Verify the SLSA L3 provenance attestation.** The cleanest tool for SLSA verification is `slsa-verifier`, which understands the container generator's attestation format directly:

```bash
slsa-verifier verify-image \
  ghcr.io/acme/svc@sha256:abc123... \
  --source-uri github.com/acme/svc \
  --source-tag v1.2.3
```

What this checks:

- The attestation was signed by the expected SLSA generator reusable-workflow identity (the "trusted builder").
- The attestation's subject digest matches the passed image digest.
- The attestation's `invocation.configSource.uri` matches the passed `--source-uri` — i.e., the image came from `acme/svc` and not some other repo that happened to publish to the same registry path.
- `--source-tag` additionally checks that the commit the builder saw corresponds to the named tag. Omit it if you want to accept any tag/branch from the source repo.

For policy enforcement (rather than a human check), also consider `cosign verify-attestation --type slsaprovenance` against the same image, using the same `--certificate-identity-regexp` pattern as the Cosign verify example above but targeting the SLSA generator's workflow identity (`https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.1.0` for the currently pinned version).

**Enforce at admission time.** Both checks above run fine from a CLI, but for ongoing enforcement consumers should wire them into admission control so unverified images can't run in the first place:

- Kubernetes with Kyverno or Sigstore `policy-controller` can enforce the same `certificate-identity-regexp` and `certificate-oidc-issuer` conditions at admission. Kyverno's `verifyImages` rule and policy-controller's `ClusterImagePolicy` both take these as structured fields.
- Registry-side policies (e.g., `cosign policy`, Harbor's Cosign integration) can gate pulls on the same identity.
- For SLSA provenance, `policy-controller` and Kyverno both support `attestations:` blocks that run CUE or Rego against the decoded provenance predicate — consumers can require, for example, a specific `builder.id` or that `invocation.configSource.uri` matches their own allowlist.

### Image pushed before signed

Container registries require the image to exist before a signature can be attached. If signing fails after push, the image is in the registry but unsigned. This is an inherent constraint of OCI registries, not a design flaw:

- The **workflow fails**, and the error message tells the adopter not to release the image
- Adopters should not tag releases from failed workflows
- Consumers who enforce Cosign verification (via Kyverno, Sigstore policy-controller, or manual `cosign verify`) will reject the unsigned image automatically
- The unsigned image is not deleted because `packages:delete` permission introduces its own risks and most callers won't grant it

The protection is defense in depth: wrangle ensures signed images are the only *successful* output, and consumer-side admission control ensures unsigned images are never *accepted*.

#### The remote registry is in the TCB

Pushing the image before signing it pulls the remote container registry into wrangle's trusted computing base for the window between `docker push` and `cosign sign`. This is an inherent property of the push-then-sign flow, and adopters should understand what it means.

A compromised or malicious registry could, during that window:

- **Serve different bytes at the pushed digest than wrangle pushed.** Because cosign signs by digest, signing a tampered blob would only succeed if the registry returned the original digest on read but served tampered bytes on pull — which most registries make hard but not impossible if the registry is fully compromised.
- **Accept the push but advertise a different manifest under the same tag** to later pullers, decoupling what wrangle signed from what consumers fetch. This is why verification must always be by digest, not by tag, on the consumer side.
- **Silently drop or corrupt the signature push**, leaving the image unsigned. Wrangle catches this if the registry returns an error — signing is hard-fail — but a malicious registry could acknowledge the signature push while not actually storing it. Consumer-side verification is what catches that, not wrangle.
- **Leak or log the OIDC token** used for the push. The token is short-lived (a few minutes) and scoped to the specific workflow run, so the blast radius is bounded, but it's still in-scope for the registry during push.

None of these can be fully eliminated without registry-side changes (e.g., a registry that accepts a signed manifest on the initial push, so there's no window between push and sign). Wrangle's current mitigations are:

- **Signing by digest, not by tag**, so a post-push tag swap can't be laundered into a matching signature.
- **ghcr.io only.** The current scope restriction means the registry shares its trust root (GitHub's infrastructure) with the runner, the OIDC issuer, and the source repo. An adopter using wrangle against ghcr.io is not meaningfully extending their TCB by adding the registry — it was already in it via Actions. An adopter using a third-party registry would be, which is one of the reasons multi-registry support is still out of scope.
- **Short-lived OIDC credentials for the push**, so a compromised registry can't replay the push later with the same identity.
- **Consumer-side digest-based verification** as the ultimate backstop. If the registry swaps bytes, the consumer's `cosign verify` and `slsa-verifier verify-image` against the expected digest will fail.

When wrangle eventually supports pushing to other registries, this section should be revisited — adopters who push to a less-trusted registry are widening their TCB by that registry's operational and security posture, and the spec should make that explicit at the point they opt in.

## Re-run behavior

Re-running the workflow after a signing or provenance failure rebuilds and re-pushes the image (producing a new digest). The signing and provenance steps then operate on the new digest, so the result is fully consistent. Adopters can safely re-run failed workflows without worrying about stale digests or mismatched attestations.

## Documentation requirements

Per `docs/SPEC.md` ("Build action directory structure"), the container build action MUST provide both this `SPEC.md` and a `README.md` in `build/actions/container/`. They serve different audiences:

- **`SPEC.md` (this file)** — contract-level documentation aimed at maintainers, reviewers, and security auditors. Forward-looking; may describe behavior still being implemented.
- **`README.md`** — user-facing how-to aimed at adopters (humans wiring wrangle into their repo) and agents (LLMs generating wrangle integrations for a project). Must only describe currently-shipped behavior.

### Required contents of `build/actions/container/README.md`

The container README MUST include each of the following sections, in this order. They exist so an adopter (or an agent) can go from "I want to build a signed container with wrangle" to a working, verifiable pipeline without reading this spec:

1. **What this action does** — a one-paragraph plain-English summary: what's produced (image + SBOM + Cosign signature + SLSA L3 provenance), what registries are supported (ghcr.io today), and what assurances the output carries.
2. **When to use which entry point** — a short decision between the **reusable workflow** (`.github/workflows/build_and_publish_container.yml`, recommended default because it wires up SLSA L3 provenance and the release gate) and the **composite action** (`build/actions/container/action.yml`, for adopters who already have a custom workflow and only want the build+SBOM+sign steps). Explain that only the reusable workflow provides the full SLSA L3 guarantee, and that consumers should depend on the reusable workflow's completion, not individual jobs.
3. **Quick start** — a copy-pasteable, fully working caller workflow that invokes the reusable workflow, with all required `permissions:`, `secrets:`, and `with:` fields filled in against a placeholder image name. The example MUST:
   - Pin wrangle's reusable workflow at a **release tag** (not `@main`), matching the `@v0.x.y` rule from `CLAUDE.md`.
   - Show only `on: push` and `on: release` triggers, not `pull_request`, to reinforce the trigger restriction (see "Trigger restriction" in this spec).
   - Include the exact `permissions:` block the workflow needs (`contents: read`, `packages: write`, `id-token: write`).
4. **Inputs, outputs, secrets** — tables that mirror the "Inputs and outputs" section of this spec but scoped to the reusable workflow (the adopter-facing surface). Link to this `SPEC.md` for the composite-action surface.
5. **Verifying the output** — the `cosign verify` and `slsa-verifier verify-image` example commands from this spec's "Verification examples" section, with a note that the identity regex must be customized to match the caller's repo and workflow filename. Include the "verify by digest, not tag" rule.
6. **What to do when the workflow fails** — a short runbook: a failed gate means the image is in the registry but not signed/attested; do not tag, promote, or deploy it; re-run the workflow; the new digest will be signed cleanly. Link to the "What happens when the gate fails" section of this spec for the full explanation.
7. **Current limitations** — the short version of this spec's "Known limitations" (ghcr.io only, no cosign SBOM attestation yet, multi-platform untested, provenance predicate v0.2). Link to this spec for the full list and upstream tracking issues.
8. **Further reading** — link to this `SPEC.md`, the top-level `docs/SPEC.md` for wrangle's overall model, and the verification tool docs (`cosign`, `slsa-verifier`).

### Constraints on the README

- **Only document shipped behavior.** If a section of this spec describes behavior that isn't implemented yet (e.g., Cosign signing before it lands in `action.yml`, or the cosign SBOM attestation tracked in "Known limitations"), the README MUST NOT present it as available. It may briefly note that the feature is planned and link to this spec, but the quick-start example and verification commands must run against the current `action.yml`.
- **Keep it agent-friendly.** Use literal copy-pasteable YAML blocks, not narrative descriptions of fields. Agents consuming the README should be able to extract the example workflow verbatim without template substitution beyond the documented placeholders.
- **Keep it in sync with implementation changes.** Any PR that changes `action.yml` in a way that affects inputs, outputs, required permissions, or observable behavior MUST update the README in the same commit. Spec-only PRs (like the one introducing this section) may leave the README's implementation details ahead of or behind the current implementation as long as the README-on-main still accurately describes shipped behavior.

## Known limitations

- **ghcr.io only.** Today the container build action is only specified, implemented, and tested against GitHub Container Registry. The permissions model (`packages: write`), registry login path, and SLSA provenance wiring all assume ghcr.io. Multi-registry support is a planned future extension — adding it requires (at minimum) reworking the permissions model for non-GitHub registries, validating the SLSA generator's behavior against each target, and re-evaluating the "The remote registry is in the TCB" section for registries that don't share GitHub's trust root.
- **SBOM not yet published as a cosign attestation.** The SBOM is uploaded as a workflow artifact and embedded in the BuildKit-native image attestation, but wrangle does not yet attach it to the image digest as a `cosign attest --type spdxjson` attestation. Consumers currently need either the workflow artifact or `docker buildx imagetools inspect` to retrieve it, instead of a single `cosign download attestation` call against the signed digest. Planned for a future release.
- **Multi-platform builds.** The action uses Buildx, which supports multi-platform builds, but this has not been tested. Multi-platform support is not currently specified or guaranteed.
- **SLSA provenance predicate version.** As of `slsa-github-generator` v2.1.0, the container generator emits `predicateType: https://slsa.dev/provenance/v0.2`. Upstream v1.0 support for the container builder is tracked in [`slsa-framework/slsa-github-generator#1524`](https://github.com/slsa-framework/slsa-github-generator/issues/1524) and has not shipped. Wrangle will adopt v1.0 predicates once upstream releases them — see "Predicate version" above for details.
- **`packages:write` always required for provenance.** Even for non-ghcr.io registries, due to GitHub Actions token handling (tracked upstream in slsa-github-generator#1257). This is one of the gaps that must be resolved before multi-registry support is feasible.
