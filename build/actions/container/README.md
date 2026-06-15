# Wrangle Build Container

Wrangle builds a container image from your Dockerfile and publishes it to ghcr.io with an SBOM and SLSA Build L3 provenance — all from a single job in your workflow. Your users get a signed VSA they can verify with one command.

## Quick start

Copy [`build_and_publish_containers.yml`](../../../gh_workflow_examples/build_and_publish_containers.yml) into `.github/workflows/` and fill in three inputs (the example wires the permissions and `gh_token` secret):

| Input | Value |
|-------|-------|
| `path` | folder containing your `Dockerfile` |
| `imagename` | `ghcr.io/<owner>/<repo>/<image>` |
| `registry` | `ghcr.io` |

## What you get

- **Build + push to ghcr.io** (other registries are out of scope — see [`SPEC.md`](./SPEC.md#current-scope-ghcrio-only)).
- **Source scan** built in — vulnerable dependencies (OSV), unsafe workflow patterns (Zizmor), and more ([details](../../../actions/scan/README.md)); a load-bearing finding blocks the build and push.
- **A BuildKit-native SBOM**, attached to the image as an OCI attestation and uploaded as a workflow artifact (SPDX JSON).
- **SLSA Build L3 provenance** for the image digest ([the requirements it meets](../../../docs/REQUIREMENTS_MAPPING.md)).
- **A signed VSA** delivered in a per-artifact `.intoto.jsonl` bundle — uploaded as a workflow artifact and additionally pushed to the registry as a best-effort OCI referrer on the image digest, so consumers can verify the image with one command.

## Good to know

- **`release-events`** (default: `non-pull-request`) gates provenance generation and verification — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating". The docker push itself happens earlier and is gated by your workflow's own `on:` triggers.
- **Release builds never use a cache** — BuildKit's shared cache isn't re-verified on hits, so a poisoned entry could reach the attested image. PR builds get a per-PR isolated cache by default, which closes PR-to-PR cache poisoning; tune that with the `pr-cache` input, documented in [`build_and_publish_container.yml`](../../../.github/workflows/build_and_publish_container.yml).
- **`pull_request_target` can't trigger this workflow** — that trigger (and `workflow_run` chained from it) is a common exploit vector, so wrangle blocks both at startup.
- **Private repos aren't supported** — the `verify` job can't pull auth-gated provenance referrers ([#182](https://github.com/TomHennen/wrangle/issues/182)).
- **Workflow outputs** are documented in [`build_and_publish_container.yml`](../../../.github/workflows/build_and_publish_container.yml) itself.
- **Enable Dependabot too** — copy [`dependabot.yml`](../../../gh_workflow_examples/dependabot.yml) to `.github/` and uncomment the `docker` entry (base-image updates). Its `github-actions` entry also keeps your `uses: TomHennen/wrangle/...` pin current.

## Verifying what you shipped

Consumers verify the image with one command — ampel fetches the VSA straight from the registry, so there's nothing to download first ([ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0):

```bash
ampel verify --subject sha256:<digest> \
  --policy git+https://github.com/TomHennen/wrangle@v0.2.2#policies/wrangle-vsa-consumer-v1.hjson \
  --collector oci:<imagename>@sha256:<digest> \
  --context expectedResourceUri:<imagename>@sha256:<digest> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

That single command checks — fail-closed — the signature, wrangle's signer identity, that the build ran in *your* repo, and that policy passed at SLSA Build L3. No ampel? See the [artifact verification guide](../../../docs/verifying_artifacts.md) for an equivalent cosign recipe and the full trust model.

The SBOM is also inspectable straight off the image: `docker buildx imagetools inspect --format '{{ json .SBOM.SPDX }}' <image>@<digest>`.

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification: failure contract, trust model, trigger restriction.
- [`docs/verifying_artifacts.md`](../../../docs/verifying_artifacts.md) — consumer verification: ampel, cosign, and the publish/attest timing model.
- [`docs/REQUIREMENTS_MAPPING.md`](../../../docs/REQUIREMENTS_MAPPING.md) — the SLSA Build L3 requirements mapping, including the per-surface cache analysis (BuildKit `type=gha`).
