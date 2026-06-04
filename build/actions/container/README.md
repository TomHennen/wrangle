# Wrangle Build Container

Build and publish a container image to ghcr.io with an SBOM, Cosign signature, and SLSA L3 provenance.

## Quick-start

Copy [`gh_workflow_examples/build_and_publish_containers.yml`](../../../gh_workflow_examples/build_and_publish_containers.yml) into your repo at `.github/workflows/` and fill in:

| Input | Value |
|-------|-------|
| `path` | path to the folder containing your `Dockerfile` |
| `imagename` | `ghcr.io/<owner>/<repo>/<image>` |
| `registry` | `ghcr.io` |

The example wires in the required permissions and `gh_token` secret. Pair with [source scan](../../../actions/scan/README.md) — build hardens *how*, source scan covers *what was committed*.

For the full design (failure contract, trust model, planned signing/provenance steps in the composite), see [`SPEC.md`](./SPEC.md). This README only describes shipped behavior.

## Build Track level

Consumed through `build_and_publish_container.yml`, the container build meets **SLSA v1.2 Build L3** if both of these conditions hold:

- **Reusable consumption only.** Calling the composite from your own workflow forfeits the build-vs-sign job separation and is **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation L3 assumes.

Release builds run with the BuildKit `type=gha` cache disabled (BuildKit doesn't re-verify cache hits, so a shared cache violates SLSA's "Isolated" requirement). PR builds default to a per-PR isolated cache. Full analysis: [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 2.

## What this action does

- Builds a Docker image from a caller-provided Dockerfile path.
- Pushes to ghcr.io (other registries out of scope — see [`SPEC.md`](./SPEC.md#current-scope-ghcrio-only)).
- Generates a BuildKit-native SBOM, attaches it to the image as an OCI attestation, and uploads it as a workflow artifact in SPDX JSON.

The reusable workflow `build_and_publish_container.yml` layers on top: `slsa-github-generator` produces L3 provenance, `cosign verify-attestation` checks that provenance against the just-pushed digest, and the release-gate job enforces the order.

Two pieces from the spec are not yet shipped — neither in the composite nor in the reusable workflow:

- **Cosign keyless signing of the image digest itself.** The reusable workflow already pulls in `cosign-installer` for `verify-attestation`, but it does not yet run `cosign sign` against the digest. No tracking issue today; please file one if you need it prioritized. Design: [`SPEC.md` §"Cosign image signing"](./SPEC.md#cosign-image-signing).
- **OSV-Scanner against the produced SBOM (non-blocking).** The SBOM is generated and uploaded, but nothing in the container path scans it yet. No tracking issue today; same suggestion. Design: [`SPEC.md` §"Failure contract"](./SPEC.md#failure-contract).

## Controlling when provenance is generated

The reusable workflow's `release-events` input controls which events trigger release-time actions: SLSA provenance generation, verification, and — via the `should-release` output — any downstream release-time job in your own workflow that gates on it. Accepted values:

- `non-pull-request` (default) — every event except `pull_request` (the common case: provenance on merges to main, tags, manual dispatches, etc.).
- `tag-only` — only `push` events to `refs/tags/*`.
- `main-and-tags` — `push` to `refs/heads/main` or `refs/tags/*`.
- A comma-separated `github.event_name` list (e.g., `push,workflow_dispatch`).

See [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating" for the full vocabulary.

```yaml
with:
  path: .
  imagename: ghcr.io/<owner>/<repo>
  registry: ghcr.io
  release-events: tag-only   # only tag pushes mint provenance
```

This input gates only the SLSA provenance and verify jobs. The docker push happens earlier in the composite and is gated by your workflow's own `on:` triggers (see [`SPEC.md` §"Trigger restriction"](./SPEC.md#trigger-restriction)).

## Controlling the PR build cache

Release builds always run cache-free — BuildKit's `type=gha` cache isn't re-verified on hits and is shared cross-build, which would violate SLSA's "Isolated" requirement ([`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 2). Not configurable.

**PR builds** default to a per-PR isolated cache. PR builds produce no attested artifact, so cache poisoning isn't an L3 concern at that layer — but it's still a CI-hygiene concern: a malicious PR with code execution can poison cache entries a *later* PR reads (PR-to-PR cache poisoning), silently corrupting that build's "tests pass" and SBOM signals ([Cacheract](https://adnanthekhan.com/2024/12/21/cacheract-the-monster-in-your-build-cache/)). The `pr-cache` input tunes the trade-off:

| `pr-cache` | PR build behavior | When to use |
|------------|-------------------|-------------|
| `isolated` (default) | Per-PR cache scope, keyed by PR number. PR A cannot write entries PR B reads; rebuilds within a PR still hit cache. | Safe default — closes PR-to-PR cache poisoning, keeps in-PR speedup. |
| `enabled` | Shares the cross-branch cache. Fastest first build, but a malicious PR can poison later PR builds. | Trusted-contributor repos. |
| `read-only` | PR builds read the shared cache but never write it. | Shared-cache reads, no PR write path. |
| `disabled` | PR builds also run cache-free. | Strict-isolation contexts. |

The scope is keyed by `github.event.pull_request.number` (a GitHub-assigned unique integer), not branch name — two PRs sharing a branch name from different forks get distinct scopes. On non-PR events the scope falls back to the ref name.

> **Never invoke this workflow from `pull_request_target`.** That trigger runs in the base-repo context with cache write access, making a fork PR the highest-risk poisoning vector. Wrangle's reusable workflows will block any workflow that uses `pull_request_target` ([#202](https://github.com/TomHennen/wrangle/issues/202)).

## SLSA attestation verification (default-on, opt-out)

The reusable workflow runs `cosign verify-attestation --type slsaprovenance` against the just-pushed image digest before declaring success. This catches the "registry served different bytes than wrangle pushed" attack window — failure blocks any downstream `needs:` job. The cert identity is pinned to the SLSA generator's tag (`v2.1.0` today) and to your repository, so attestations from a different generator version or a different repo do not pass.

To opt out (custom verification flow):

```yaml
with:
  verify-image: false
```

**Private-repo limitation.** Verify currently does no registry auth, so private-repo adopters must set `verify-image: false` and verify in their own job. See [#182](https://github.com/TomHennen/wrangle/issues/182). When `cosign sign` of the image digest lands, this verify job will additionally check the image signature against the caller's `workflow_ref`.

### Verifying the VSA

Beyond the registry-bytes check above, on release the workflow emits a single signed SLSA Verification Summary Attestation (VSA) recording that the image's SLSA provenance passed the `wrangle-provenance-container-v1` PolicySet. The VSA's `resourceUri` is the OCI image ref `<imagename>@sha256:<digest>` — what a consumer pulls — and its subject is that digest. A consumer trusts that single signed VSA instead of re-running the policy engine.

Unlike the npm/Go build types, the container VSA is **stored in the registry** as an OCI referrer on the image digest (containers produce no GitHub release), so you fetch it with `cosign download attestation` rather than from a release asset. The VSA is keyless-signed by **wrangle's** reusable workflow (`build_and_publish_container.yml`), not your own.

First fetch the VSA from the registry:

```bash
# The VSA is an OCI referrer on the image digest.
cosign download attestation \
  --predicate-type https://slsa.dev/verification_summary/v1 \
  <imagename>@sha256:<digest> > vsa.intoto.jsonl
```

**Recommended — `ampel verify`.** The container VSA's subject is the image **digest** (there is no file blob to hand `cosign verify-blob-attestation`), so ampel is the digest-native complete check: one command confirms signature, keyless identity, and predicate fields against a wrangle-hosted consumer policy fetched by locator — you author no policy. Requires installing ampel (one Go binary).

```bash
ampel verify \
  --subject sha256:<digest> \
  --policy git+https://github.com/TomHennen/wrangle@<version>#policies/wrangle-vsa-consumer-v1.hjson \
  --attestation vsa.intoto.jsonl \
  --context expectedResourceUri:<imagename>@sha256:<digest>
```

**Without ampel.** `cosign verify-blob-attestation` is blob/file-oriented (npm/Go) — the container VSA's subject is the image digest, not a file on disk, so there is no blob to hand it. Confirm the VSA subject is your digest and the predicate fields with a `jq` decode:

```bash
payload="$(jq -r '.dsseEnvelope.payload' vsa.intoto.jsonl | base64 -d)"
jq -e '.predicate.subject[0].digest.sha256 == "<digest>"' <<<"$payload"
jq -e '.predicate.verificationResult == "PASSED"' <<<"$payload"
jq -e '.predicate.resourceUri == "<imagename>@sha256:<digest>"' <<<"$payload"
jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3")' <<<"$payload"
```

The `jq` decode does not check the VSA *signature* — for the full check (signature + keyless signer identity + fields against the digest subject) use ampel above.

> **`slsa-verifier verify-vsa` is not usable here.** It only verifies *key-signed* VSAs (it requires `--public-key-path`); wrangle's VSAs are keyless (Fulcio/Sigstore), so there is no identity flag to pass. Tracked under the [Attestation trust gaps](../../../README.md) section / [#295](https://github.com/TomHennen/wrangle/issues/295).

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
