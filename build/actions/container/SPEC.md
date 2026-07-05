# Container Build Action — Specification

## Overview

The container build action builds a Docker image, generates and scans an SBOM, publishes the image, signs it, and produces SLSA L3 provenance. It implements the build stage failure contract from `docs/SPEC.md` for container artifacts.

Two components work together:

| Component | Location | Scope |
|-----------|----------|-------|
| **Composite action** | `build/actions/container/action.yml` | Build, SBOM, publish, sign |
| **Reusable workflow** | `.github/workflows/build_and_publish_container.yml` | Orchestrates composite action + SLSA L3 provenance + gate |

The split exists because SLSA L3 requires the provenance to be produced by an isolated builder: wrangle runs `actions/attest-build-provenance` inside the reusable workflow, which a composite action cannot.

### Current scope: ghcr.io only

This spec and the current implementation are scoped to **GitHub Container Registry (`ghcr.io`)**. The `registry` input accepts any hostname and `docker/login-action` will technically log in anywhere, but the permissions model, SLSA provenance wiring, and trust assumptions are all tailored to ghcr.io today. Pushing to Docker Hub, ECR, GAR, Harbor, or any other OCI registry is **not supported** right now — treat it as out of scope, not just untested.

Multi-registry support is a planned extension. See "Known limitations" for the specific gaps that would need to close before other registries are supported.

## Inputs and outputs

### Composite action inputs

| Input | Required | Description |
|-------|----------|-------------|
| `path` | yes | Relative path to the directory containing the Dockerfile |
| `dockerfile` | no | Path to the Dockerfile. Default: `{path}/Dockerfile` with `path` as the build context. When set, the build context is the repo root (so the Dockerfile can `COPY` files outside `path`). `path` still names the artifacts. |
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
| `dockerfile` | no | Passed through to composite action (see the composite-action input above) |
| `imagename` | yes | Passed through to composite action |
| `registry` | yes | Passed through to composite action |

### Reusable workflow secrets

None. Every job authenticates with its own `GITHUB_TOKEN` (each requests the
`packages: write` / `id-token: write` it needs), so the caller passes no secrets.

### Reusable workflow outputs

The reusable workflow surfaces the identifiers a downstream release job needs to act on the just-built image. Each output is only meaningful if the gate job passed — consumers must depend on the reusable workflow completing successfully, not read these outputs from a failed run.

| Output | Description |
|--------|-------------|
| `digest` | The image digest of the published image (`sha256:...`), forwarded from the composite action's build-and-push step. Identifies the exact image that was signed and attested. |
| `imagename` | Validated, lowercased image name (e.g., `ghcr.io/owner/repo/image`), forwarded from the composite action. |
| `metadata-artifact-name` | Name of the uploaded workflow artifact containing the SBOM and any scan output (e.g., `container-metadata-<shortname>`). Downstream jobs can fetch it via `actions/download-artifact`. Naming and contents follow the unified-metadata convention; see [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout." |

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
14. Generate SLSA L3 provenance (actions/attest-build-provenance, run inside the reusable workflow; pushed to the registry as an OCI 1.1 referrer on the image digest)
15. Verify the provenance and emit the signed SLSA VSA (ampel against wrangle-provenance-container-v1; gated on should-release); push the VSA to the registry as its own OCI referrer by image digest (cosign attach attestation) and deliver the combined provenance+VSA bundle as a workflow artifact
16. Gate job — verify both build+sign and provenance succeeded
```

Step 15 is the `verify` job: it both verifies the image provenance and emits the single signed VSA a downstream consumer trusts. ampel evaluates the image provenance against `wrangle-provenance-container-v1` — fail-closed against the PolicySet's `common.identities` (only wrangle's reusable-workflow signer passes) plus the SLSA tenets — and bnd-signs the resulting VSA keyless with the calling workflow's OIDC identity. Because ampel pulls the provenance from the registry by digest, this verification also catches the "registry served different bytes than wrangle pushed" window. `actions/attest-build-provenance` names `build_and_publish_container.yml` as the provenance `builder.id` and emits buildType `https://actions.github.io/buildtypes/workflow/v1`, the exact values the container PolicySet bakes. Each build type's provenance carries a distinct `builder.id` (its own reusable workflow path), which is why the container needs its own PolicySet — a single PolicySet cannot bake two builder IDs.

Step 15 differs from the npm/Go VSA flow in *storage*: containers produce no GitHub release, so the signed VSA is pushed to the registry as its own OCI referrer on the image digest (`cosign attach attestation`, which uploads the already-bnd-signed VSA statement verbatim — it does not re-sign) rather than attached to a release asset, and the combined provenance+VSA bundle is uploaded as a workflow artifact. The container has one subject (the image digest) → one VSA statement, and `cosign attach attestation` accepts that single Sigstore-bundle line and round-trips it through `cosign download attestation` with its `verificationMaterial` intact — it rejects a multi-line concatenation, which is why the by-digest referrer carries the VSA alone (the provenance is already its own referrer from `attest-build-provenance`). Because the by-digest VSA referrer is the path the container consumer verifies, that push fails closed (through the shared transient-Sigstore retry); a missing by-digest VSA is a real delivery gap. Unifying every build type onto a single GitHub attestation-store delivery is tracked in [#372](https://github.com/TomHennen/wrangle/issues/372). Step 15 also differs in how ampel *reads* the build provenance it evaluates: the npm/Go/Python flows feed ampel the attest job's local Sigstore bundle via the `jsonl:` collector, but the container provenance lives only in the registry as an OCI referrer, so the container verify job uses the `oci:` collector to list the image's referrers and select the signed `attest-build-provenance` bundle. `cosign attach` runs inside `actions/verify` in the same process as emit+sign, so the unsigned VSA never crosses a step boundary; the verify job logs in to ghcr first and requests `packages: write` (not `contents: write`) for both the provenance pull and the VSA push.

### Provenance verification in the `verify` job

Verification is part of the `verify` job, gated only on `should-release` (it is not opt-out-able). ampel verifies the image provenance against the `wrangle-provenance-container-v1` PolicySet:

- The PolicySet's `common.identities` pins wrangle's reusable-workflow signer (`TomHennen/wrangle/.github/workflows/build_and_publish_container.yml`). The attest step runs inside this reusable workflow, so its `job_workflow_ref` is both the Sigstore cert SAN and the provenance `builder.id`; verification fails closed unless this exact workflow signed the bundle. This is the load-bearing binding.
- The provenance carries `predicateType: https://slsa.dev/provenance/v1`, the predicate `actions/attest-build-provenance` emits — the SLSA tenets are checked against it.
- ampel pulls the provenance from the registry by digest via the `oci:` collector, so verification also confirms the registry serves the bytes wrangle pushed.

Failing verification fails the workflow, which blocks any downstream release-time job depending on it via standard `needs:` propagation.

When `cosign sign` of the image digest lands in the composite action (currently planned per "Signing details"), the `verify` job will additionally run `cosign verify` against the image signature. The cert identity for that step is the adopter's `${{ github.workflow_ref }}`, not wrangle's reusable workflow — different signer, different cert subject.

## Input validation

All inputs are passed through `env:` blocks — never interpolated directly in `run:` blocks (prevents expression injection).

| Input | Validation |
|-------|-----------|
| `path` | Must be relative (no leading `/`), no `..` traversal, characters match `^[a-zA-Z0-9_./-]+$` |
| `dockerfile` | When set, same rules as `path` (relative, no `..`, `^[a-zA-Z0-9_./-]+$`) via `lib/validate_path.sh` — it flows into the build as `docker/build-push-action`'s `file`. Empty is allowed and selects the default `path`-subdirectory context. |
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
| SLSA provenance | **Pipeline stops**; image already pushed | Same shape as Cosign: the image has shipped to the registry, but wrangle's notion of a *successful release* requires provenance. Failing the gate tells adopters not to promote the image, and the error message instructs them to re-run. Consumers enforcing provenance via `gh attestation verify` (or the signed VSA) will reject the un-attested image. As with signing, the image being physically present in the registry isn't the problem — an unsigned/un-attested image has effectively not shipped under wrangle's contract as long as consumers enforce verification. |
| VSA workflow-artifact upload | **Pipeline stops** (fail-closed) | The bundle is the consumer trust artifact; the workflow-artifact upload (`if-no-files-found: error`) is the guaranteed delivery, so a failure there fails the verify job and, via `needs:` propagation, the workflow. |
| VSA registry-push (OCI referrer) | **Pipeline stops** (fail-closed) | The by-digest VSA referrer is the path the container consumer verifies, so a missing one is a real delivery gap. A single VSA statement pushes normally; `cosign attach attestation` runs through the shared transient-Sigstore retry, and a genuine failure fails the verify job rather than shipping an image whose VSA can't be found by digest. |

### Error messages on security-critical failures

When signing or provenance fails, the error message must tell the action adopter what happened and what to do. Generic "step failed" output is not sufficient — adopters need to know the image is unsafe to release and that re-running the workflow is the correct remediation.

| Failure | Error message |
|---------|--------------|
| Cosign signing (retries exhausted) | `wrangle: FATAL: Cosign signing failed after N attempts. The image was pushed but is NOT signed and MUST NOT be released. Re-run this workflow to retry.` |
| SLSA provenance | `wrangle: FATAL: SLSA provenance generation failed. The image has no provenance and MUST NOT be released. Re-run this workflow to retry.` |

The Cosign error is emitted directly by the signing step in the composite action. The SLSA provenance error is emitted by the **gate job** in the reusable workflow: the gate is the single point that observes whether the `attest:` job succeeded, so it is the natural place to surface the adopter-facing release-blocked message.

## Cosign image signing

The image is signed using Cosign keyless signing (Sigstore OIDC). This is distinct from the SLSA provenance attestation — they answer different questions:

| | Cosign image signature | SLSA provenance attestation |
|---|---|---|
| What it signs | The image digest directly | An in-toto attestation about how the image was built |
| What it proves | "This image was produced by a trusted GitHub Actions identity" | "This image was built from commit X in repo Y by builder Z" |
| How consumers verify | `cosign verify` | `gh attestation verify oci://<image>@<digest> --signer-workflow ...` |
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

Provenance is generated by `actions/attest-build-provenance`, run as a step inside an `attest:` job in wrangle's own reusable workflow (`build_and_publish_container.yml`).

### What it produces

- An in-toto attestation carrying a SLSA provenance predicate, signed via Sigstore keyless signing
- The attestation is pushed to the container registry as an OCI 1.1 referrer on the image digest
- A transparency log entry in Rekor

### Predicate version and builder identity

`actions/attest-build-provenance` emits `predicateType: https://slsa.dev/provenance/v1` and buildType `https://actions.github.io/buildtypes/workflow/v1`. Crucially, it names the workflow that ran the build as the provenance `builder.id` — here, `build_and_publish_container.yml`'s `job_workflow_ref`. These are the exact values the container VSA PolicySet (`wrangle-provenance-container-v1`) bakes.

This is the property the old `slsa-github-generator` container builder could not give wrangle: the generator emitted `predicateType: https://slsa.dev/provenance/v0.2` and set `builder.id` to *the generator itself*, not to the workflow that ran the build — leaving a build-confusion gap (a consumer could not tell, from the builder identity alone, which trusted workflow produced the image). Running `actions/attest-build-provenance` inside wrangle's reusable workflow closes that gap and emits a v1 predicate in the same move.

The L3 "hardened build platform" property is unchanged by the switch. L3 comes from the provenance being produced by an isolated, trusted builder; wrangle's reusable workflow *is* that builder. The `attest:` step runs inside it, so its `job_workflow_ref` is both the Sigstore certificate SAN and the provenance `builder.id`. `actions/attest-build-provenance` is an action, not a generator reusable workflow, but the isolation guarantee is provided by wrangle's reusable workflow being the trusted builder — not by the attestation tooling running as a separate `uses:` job.

### Why it runs in the reusable workflow, not the composite action

The `attest:` job must run in the reusable workflow rather than inside the composite action. This is a security property: the reusable workflow is the isolated builder whose `job_workflow_ref` becomes the provenance `builder.id`, and keeping attestation in a separate job from the build step is what gives wrangle the build-vs-attest separation a composite action (running entirely on the caller's runner under the caller's identity) cannot.

### Trigger restriction

Neither Cosign signing nor SLSA provenance runs on `pull_request` triggers. SLSA provenance is gated on the `release-events` input (default `non-pull-request`); see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating" for the full vocabulary. The trigger restriction is a deliberate design rule, not just a workaround for an upstream limitation:

- **PRs must not produce artifacts that look production-ready.** A Cosign-signed image from a PR branch is binary-indistinguishable from a signed release image at the consumer's verification step, and its signing identity would be tied to the PR branch (or worse, a fork) rather than the release branch. Consumers whose verification policy accepts "any signature from this repo" would treat a PR-built image as a release — exactly the shape of a release-confusion supply chain attack. The safe default is that PR builds *cannot* produce a signed or attested image, period.
- **SBOM generation and vulnerability scanning do run on PRs.** Those steps surface actionable information to the PR author (new CVEs, new dependencies pulled in by the change) without producing anything a consumer could mistake for a release. SBOM scan findings are uploaded as SARIF so they appear on the PR's Security tab.
- **Skipping provenance on PRs is wrangle's own choice, not a tooling limitation.** The `attest:` job runs inside wrangle's reusable workflow, so wrangle controls whether it runs at all; it gates the job on `release-events` and skips it on PRs deliberately, for the same release-confusion reason signing is skipped. (`actions/attest-build-provenance` would happily run on a `pull_request` event — wrangle declines to, by policy.)

In practice a PR-triggered run executes: validate → build → push → SBOM extract → SBOM scan, and then exits without invoking signing, provenance, or the release gate. The gate job's success condition encodes the full release contract (build + SBOM + sign + provenance), which is only achievable on non-PR events — so PR runs never produce a successful gate, and adopters should not configure release tagging or deployment workflows to react to PR-triggered container builds.

`release-events` currently scopes only the SLSA provenance job in the container reusable workflow. The docker push happens mid-composite inside `build/actions/container` and is gated by the workflow's own trigger configuration; tightening `release-events` (e.g., to `tag-only`) prevents provenance from being produced on non-tag events but does not stop the push itself. This asymmetry is documented in [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating" and is expected to be resolved when the container build is restructured to separate build from push (or when an explicit publish gate is added).

### Private repos

`actions/attest-build-provenance` keyless-signs against GitHub's Sigstore
instance, which keeps private-repo attestations off the public Rekor log — so
no private repo name leaks and no opt-in input is needed (unlike the former
slsa-github-generator, whose public-Rekor posting required an explicit toggle).

## Gate job

The reusable workflow includes a gate job that requires both the build job (including Cosign signing) and the SLSA provenance job to succeed. This enforces the hard-fail contract:

- If Cosign signing fails → build job fails → gate fails → workflow fails
- If SLSA provenance fails → provenance job fails → gate fails → workflow fails
- If both succeed → gate passes → workflow succeeds

The gate job is the single point that downstream consumers (deployment workflows, release tags) should depend on. Consumers that depend on individual upstream jobs rather than the gate can race with a late failure and treat an unsigned or un-attested image as released — so always depend on the reusable workflow's completion, not on its internal job names.

### What happens when the gate fails

When the gate job fails, the reusable workflow as a whole fails with a non-zero conclusion. Concretely:

- **Downstream jobs don't run.** Any job in the calling workflow that declares `needs:` on the reusable workflow — typically release tagging, deployment, image promotion to a `:stable` tag, or GitHub Release creation — is skipped by GitHub Actions. This is the primary protection against adopters accidentally releasing a failed build.
- **The fatal error message is emitted.** The failing step (for Cosign: the signing step inside the composite action; for SLSA provenance: the gate job, which is the single point that observes the `attest:` job's outcome) writes the wrangle error message from the "Error messages on security-critical failures" table. The adopter sees a clear instruction to re-run the workflow, not a generic "job failed."
- **The image is already in the registry.** Image push happens before signing (see "Image pushed before signed"), so when the gate fails, a pushed-but-unsigned or pushed-but-un-attested image exists at the computed digest. Wrangle's contract is that this image **must not be treated as a release**: no release tag, no deployment, no promotion. The defense is layered — the gate blocks downstream jobs, the error message blocks adopters, and consumer-side verification (`cosign verify` / `gh attestation verify`) blocks end users even if the first two layers are bypassed.
- **No auto-rollback, no auto-delete.** Wrangle does not attempt to delete the unsigned image from the registry. `packages: delete` is a broader permission than most callers will grant, and a failed delete (e.g., if the registry is the reason signing failed) would turn a recoverable failure into an unrecoverable one. The image stays in the registry; re-running the workflow produces a new digest.
- **Re-run is the remediation.** Adopters re-run the workflow; a new build produces a new digest, and signing and provenance are attempted fresh against that digest. See "Re-run behavior".

## Permissions

### Composite action (inherited from calling workflow)

| Permission | Scope | Why |
|------------|-------|-----|
| `contents` | `read` | Checkout source |
| `packages` | `write` | Push image to registry, attach Cosign signature |
| `id-token` | `write` | Keyless Cosign signing via Sigstore OIDC |

### Attest job (in reusable workflow)

| Permission | Scope | Why |
|------------|-------|-----|
| `id-token` | `write` | OIDC token for Sigstore keyless signing of the provenance attestation |
| `attestations` | `write` | Write the provenance to GitHub's attestation store |
| `packages` | `write` | Push the attestation referrer to the registry |
| `contents` | `read` | `download-artifact` reads the same-run build outputs |

### verify job (in reusable workflow)

| Permission | Scope | Why |
|------------|-------|-----|
| `id-token` | `write` | OIDC token for bnd keyless signing of the VSA |
| `packages` | `write` | Pull the image's provenance for the ampel collector **and** push the VSA referrer to the registry |

Note the absence of `contents: write`: the container VSA is delivered as its own registry referrer (and the combined bundle as a workflow artifact), not attached to a GitHub release, so the verify job needs no `contents` write scope. (npm/Go verify jobs *do* request `contents: write` because they attach the VSA to a release.) The container caller grants only `contents: read`, so requesting `contents: write` here would be a startup-failing permission escalation. Unifying every build type onto a single GitHub attestation-store delivery is tracked in [#447](https://github.com/TomHennen/wrangle/issues/447)/[#372](https://github.com/TomHennen/wrangle/issues/372).

## BuildKit-native provenance vs SLSA L3

The `docker/build-push-action` with `provenance: mode=max` produces BuildKit-native provenance (in-toto attestation embedded in the OCI manifest). This is ecosystem-level provenance — useful but not cryptographically signed by a trusted third party.

SLSA L3 provenance via `actions/attest-build-provenance`, run inside wrangle's reusable workflow, is a stronger guarantee: it's produced by an isolated trusted builder (the reusable workflow, named as the provenance `builder.id`), signed keyless via Sigstore OIDC, and independently verifiable via `gh attestation verify`. Both are generated; they are complementary, not redundant.

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

1. **Workflow artifact (available now).** The composite action writes to `metadata/container/<shortname>/sbom.spdx.json` and uploads that directory as the workflow artifact `container-metadata-<shortname>`. Downstream jobs can fetch it with `actions/download-artifact`; humans can download it from the Actions run page. The reusable workflow exposes the artifact name as the `metadata-artifact-name` output so callers don't have to hardcode the naming convention. The directory layout follows the unified-metadata convention shared across all build types — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout."
2. **Embedded in the BuildKit image attestation (available now).** Because the build step is invoked with `sbom: true`, BuildKit attaches the SBOM to the OCI image manifest as an in-toto attestation. Consumers can retrieve it from the image itself, without access to the original workflow run, via:
   ```bash
   docker buildx imagetools inspect --format '{{ json .SBOM.SPDX }}' \
     ghcr.io/<owner>/<repo>/<image>@sha256:<digest>
   ```
3. **Cosign SBOM attestation (planned, not yet implemented).** A future release will additionally attach the SBOM to the signed image digest as `cosign attest --type spdxjson`, so that verified consumers can fetch it with `cosign download attestation` and be sure it's tied to the same digest the signature covers. See "Known limitations".

Adopters documenting their security story to consumers should pick (2) as the canonical source today — it's the easiest to retrieve from just an image reference, and doesn't depend on the workflow artifact still existing (GitHub retains workflow artifacts for a limited window).

### Where to find the VSA

The signed SLSA VSA (`predicateType: https://slsa.dev/verification_summary/v1`) is pushed to the **registry as its own OCI referrer** on the image digest — the container has one subject (the image digest) → one VSA statement, which `cosign attach attestation` round-trips cleanly by digest. Containers produce no GitHub release (npm/Go/Python instead attach the bundle to a release), so the by-digest referrer is the canonical retrieval path; the combined provenance+VSA `<image-basename>-<digest>.intoto.jsonl` bundle is **additionally** uploaded as a **workflow artifact**. The provenance is its own separate referrer (from `attest-build-provenance`).

Consumers retrieve the VSA from the image reference:

```bash
cosign download attestation \
  --predicate-type https://slsa.dev/verification_summary/v1 \
  ghcr.io/<owner>/<repo>/<image>@sha256:<digest> > vsa.intoto.jsonl
```

Or pull the VSA line out of the combined `<image-basename>-<digest>.intoto.jsonl` workflow artifact instead. Either way, verify it with `cosign verify-blob-attestation` (the signer-identity check — wrangle's VSAs are keyless, so this is the usable path). `slsa-verifier verify-vsa` is *not* usable here: it only verifies key-signed VSAs (it requires `--public-key-path`), and wrangle's VSAs are keyless (Fulcio/Sigstore). See the README's "Verifying the VSA" for the exact flags.

### Guidance for action adopters

Adopters should communicate their signing/provenance story to their consumers:
- Document that images are signed and how to verify them (full example commands below)
- Publish the expected signing identity (the GitHub Actions OIDC identity for their repo/workflow)
- Note that unsigned images from failed workflows may exist in the registry and should not be used

#### Verification examples

Throughout this section, assume the example image is `ghcr.io/acme/svc@sha256:abc123...`, published from `github.com/acme/svc` by the workflow `.github/workflows/release.yml` on refs matching `refs/tags/v*`. Adopters should replace these values with their own repo, workflow filename, and ref pattern, then publish the resulting commands to their consumers.

**Verify the Cosign image signature.** For a single, specific release, cosign's GitHub-Actions-aware flags let you pin the verification to an exact workflow, repository, and ref without writing regexes:

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/acme/svc/.github/workflows/release.yml@refs/tags/v1.2.3 \
  --certificate-github-workflow-repository acme/svc \
  --certificate-github-workflow-ref refs/tags/v1.2.3 \
  ghcr.io/acme/svc@sha256:abc123...
```

Notes on the flags:

- `--certificate-oidc-issuer` is mandatory for keyless verification and must be exactly `https://token.actions.githubusercontent.com` for GitHub Actions signatures. Omitting it — or letting it default — allows signatures from any Sigstore OIDC issuer, which defeats the identity binding.
- `--certificate-identity` is also mandatory. The full Fulcio subject encodes the signing workflow file and ref, so this flag alone already rejects signatures from forks, other workflows in the same repo, PR branches, or different refs.
- `--certificate-github-workflow-repository` and `--certificate-github-workflow-ref` are GitHub-specific additional assertions that cross-check cert extension fields populated by Fulcio from the GitHub OIDC token. They're redundant with a fully pinned `--certificate-identity` in the happy path, but they catch the case where an attacker crafts an identity string that doesn't match the cert's actual workflow claims — defense in depth costs one extra line. The other GitHub-workflow flags (`--certificate-github-workflow-name`, `--certificate-github-workflow-trigger`, `--certificate-github-workflow-sha`) can be added for stricter policies.
- **Verify by digest, never by tag.** A tag-based verify races with tag mutation and is the first thing an attacker tampering with a registry would exploit.

For policies that accept **multiple** releases under the same workflow (e.g., "any signed build from `.github/workflows/release.yml@refs/tags/v*`"), substitute `--certificate-identity-regexp '^https://github\.com/acme/svc/\.github/workflows/release\.yml@refs/tags/v'` (anchored) and `--certificate-oidc-issuer-regexp` as needed. The regex form is strictly more permissive; prefer the exact-match form whenever the caller knows the specific tag.

**Verify the SLSA L3 provenance attestation.** The provenance is stored as an OCI referrer on the image digest; verify it with `gh attestation verify`, pinning wrangle's reusable workflow as the signer:

```bash
gh attestation verify oci://ghcr.io/acme/svc@sha256:abc123... \
  --repo acme/svc \
  --signer-workflow TomHennen/wrangle/.github/workflows/build_and_publish_container.yml
```

What this checks:

- The attestation was signed by wrangle's reusable workflow identity (`--signer-workflow`), which is the provenance `builder.id` — the "trusted builder." Verification fails closed unless this exact workflow signed the bundle.
- The attestation's subject digest matches the passed image digest.
- `--repo` scopes the attestation to the caller's repo — i.e., the image's provenance was stored against `acme/svc` and not some other repo that happened to publish to the same registry path.

**Enforce at admission time.** Both checks above run fine from a CLI, but for ongoing enforcement consumers should wire them into admission control so unverified images can't run in the first place. The policy engine should assert the same facts the CLI commands above assert — the same signing identity + issuer + workflow claims for Cosign, and the same `builder.id` (wrangle's reusable workflow) and source repo for SLSA — so that what policy rejects at admission is the same thing a human running `cosign verify` / `gh attestation verify` would reject at the terminal:

- Kubernetes with Kyverno or Sigstore `policy-controller` can assert the same `--certificate-identity` / `--certificate-oidc-issuer` / GitHub workflow claims at admission. Kyverno's `verifyImages` rule and policy-controller's `ClusterImagePolicy` both take these as structured fields.
- Registry-side policies (e.g., `cosign policy`, Harbor's Cosign integration) can gate pulls on the same identity.
- For SLSA provenance, `policy-controller` and Kyverno both support `attestations:` blocks that run CUE or Rego against the decoded provenance predicate — consumers can require, for example, a specific `builder.id` (wrangle's reusable workflow path) or that the build's source repo matches their own allowlist.

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
- **Consumer-side digest-based verification** as the ultimate backstop. If the registry swaps bytes, the consumer's `cosign verify` and `gh attestation verify` against the expected digest will fail.

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
5. **Verifying the output** — the `cosign verify` and `gh attestation verify` example commands from this spec's "Verification examples" section, with a note that the identity regex must be customized to match the caller's repo and workflow filename. Include the "verify by digest, not tag" rule.
6. **What to do when the workflow fails** — a short runbook: a failed gate means the image is in the registry but not signed/attested; do not tag, promote, or deploy it; re-run the workflow; the new digest will be signed cleanly. Link to the "What happens when the gate fails" section of this spec for the full explanation.
7. **Current limitations** — the short version of this spec's "Known limitations" (ghcr.io only, no cosign SBOM attestation yet, multi-platform untested). Link to this spec for the full list and upstream tracking issues.
8. **Further reading** — link to this `SPEC.md`, the top-level `docs/SPEC.md` for wrangle's overall model, and the verification tool docs (`cosign`, `gh attestation verify`).

### Constraints on the README

- **Only document shipped behavior.** If a section of this spec describes behavior that isn't implemented yet (e.g., Cosign signing before it lands in `action.yml`, or the cosign SBOM attestation tracked in "Known limitations"), the README MUST NOT present it as available. It may briefly note that the feature is planned and link to this spec, but the quick-start example and verification commands must run against the current `action.yml`.
- **Keep it agent-friendly.** Use literal copy-pasteable YAML blocks, not narrative descriptions of fields. Agents consuming the README should be able to extract the example workflow verbatim without template substitution beyond the documented placeholders.
- **Keep it in sync with implementation changes.** Any PR that changes `action.yml` in a way that affects inputs, outputs, required permissions, or observable behavior MUST update the README in the same commit. Spec-only PRs (like the one introducing this section) may leave the README's implementation details ahead of or behind the current implementation as long as the README-on-main still accurately describes shipped behavior.

## Known limitations

- **ghcr.io only.** Today the container build action is only specified, implemented, and tested against GitHub Container Registry. The permissions model (`packages: write`), registry login path, and SLSA provenance wiring all assume ghcr.io. Multi-registry support is a planned future extension — adding it requires (at minimum) reworking the permissions model for non-GitHub registries, validating the attestation referrer push against each target, and re-evaluating the "The remote registry is in the TCB" section for registries that don't share GitHub's trust root.
- **SBOM not yet published as a cosign attestation.** The SBOM is uploaded as a workflow artifact and embedded in the BuildKit-native image attestation, but wrangle does not yet attach it to the image digest as a `cosign attest --type spdxjson` attestation. Consumers currently need either the workflow artifact or `docker buildx imagetools inspect` to retrieve it, instead of a single `cosign download attestation` call against the signed digest. Planned for a future release.
- **Multi-platform builds.** The action uses Buildx, which supports multi-platform builds, but this has not been tested. Multi-platform support is not currently specified or guaranteed.
- **`packages:write` required for the registry referrers.** The attest and verify jobs push their attestations to the registry as OCI referrers on the image digest, so they need `packages: write` even though the provenance signing itself is keyless. For non-ghcr.io registries this referrer-push path is one of the things multi-registry support would need to re-validate.
