# Wrangle Build npm

Wrangle builds your npm or pnpm package, runs your tests, generates an SBOM, produces SLSA Build L3 provenance, and publishes to npmjs.org via Trusted Publishing — no `NPM_TOKEN` in your repo. Your users get a signed VSA they can verify with one command. The package manager comes from your lockfile: `package-lock.json` / `npm-shrinkwrap.json` means npm, `pnpm-lock.yaml` means pnpm.

One wrinkle is npm's, not wrangle's: the publish step must live in *your* workflow, because npm's OIDC token must come from the caller's workflow filename ([npm/documentation#1755](https://github.com/npm/documentation/issues/1755)). The example wires it — see [Your publish job](#your-publish-job).

## Quick start

Copy [`build_npm.yml`](../../../gh_workflow_examples/build_npm.yml) into `.github/workflows/`. It wires the permissions, the build call, and the publish job — most adopters only need to set `path`:

```yaml
jobs:
  build:
    permissions:
      contents: write         # verify attaches the VSA to the release on tags
      id-token: write         # Sigstore keyless signing
      attestations: write     # GitHub-issued SLSA provenance
      actions: read           # source scan
      security-events: write  # scan findings -> Security tab
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml@v0.3.1 # zizmor: ignore[unpinned-uses] - immutable
    with:
      path: "."
      release-events: tag-only   # only tag pushes publish

  publish:
    # ... see the example: gates on should-release, verifies, then publishes
```

## Before first use

These steps set up [npm Trusted Publishing](https://docs.npmjs.com/trusted-publishers/): CI publishes via OIDC, so no token ever lives in your repo. Complete them in order. Already publishing this package via Trusted Publishing? Skip step 1, point your trusted publisher at `build_npm.yml` (step 2), and double-check step 3.

1. **Brand-new package: bootstrap the first version manually.** npm Trusted Publishing can't publish a package's *first* version ([npm/cli#8544](https://github.com/npm/cli/issues/8544)) — there is no PyPI-style "pending publisher" flow. Run `npm publish` once from a maintainer's terminal to mint the initial version; skipping this makes the first workflow run fail with a non-obvious "package not found".
2. **Configure the trusted publisher** — npmjs.com → your package → Settings → Trusted publishing. Pin your repo and the workflow filename (`build_npm.yml`).
3. **Enable "Require two-factor authentication and disallow tokens"** (Settings → Publishing access), leaving Trusted Publishing as the only publish path. Without it, a stolen token can push to the registry without ever touching your CI. Then revoke any token used in step 1.

## What you get

- **npm or pnpm, auto-detected** from the lockfile; for pnpm, Corepack honors `package.json`'s `packageManager` field — set it for deterministic builds.
- **Your scripts run as usual** — `scripts.build` if present, `scripts.test` unless it's npm's default placeholder, then `npm pack` / `pnpm pack`.
- **Source scan** built in — vulnerable dependencies (OSV), unsafe workflow patterns (Zizmor), and more ([details](../../../actions/scan/README.md)); a load-bearing finding blocks publish.
- **An SPDX SBOM, scan findings, and the signed bundle** in one `npm-metadata-<sn>` workflow artifact ([what's in it](../../../docs/metadata_layout.md)).
- **SLSA Build L3 provenance** ([the requirements it meets](../../../docs/REQUIREMENTS_MAPPING.md)), in addition to the L2 attestation `npm publish --provenance` writes to the registry.
- **Release assets on tag pushes** — the tarball and its `<tarball>.intoto.jsonl` bundle (signed VSA + provenance) as a flat verify-pair, plus an `npm-metadata-<sn>.zip` with the SBOM + scan results. Downstream users verify with one command. wrangle creates the tag's GitHub Release if one doesn't exist yet (published, auto-generated notes); pre-create it yourself only for custom notes or a draft.

## Your publish job

Publishing happens in your workflow, so two things there are load-bearing — both already wired in the example:

1. **Gate on `should-release`**, so you publish only on release events (wrangle can't enforce this from inside the reusable workflow):

   ```yaml
   publish:
     if: ${{ needs.build.outputs.should-release == 'true' }}
     needs: [build]
   ```

2. **Verify before you publish** — run wrangle's [`verify-vsa`](../../../actions/verify-vsa/README.md) action between `download-artifact` and `npm publish`, piping the build's `resource-uri` output, so the exact bytes leaving the runner are the bytes that passed wrangle's policy:

   ```yaml
   - uses: TomHennen/wrangle/actions/verify-vsa@v0.3.1 # zizmor: ignore[unpinned-uses] - immutable
     with:
       path: dist/
       resource-uri: ${{ needs.build.outputs.resource-uri }}
   ```

Skip the gate and you publish on every non-PR event; skip verify-vsa and you may publish bytes wrangle's policy never blessed.

## Good to know

- **Node version resolution**: `node-version` input → `.nvmrc` → `package.json` `engines.node` → a wrangle-default LTS. Set one of the first three if you care about a specific version.
- **Lifecycle hooks fire normally** (`prepare`, `prepack`, `postpack`, dependency `install` hooks). `prepublishOnly` does NOT — your publish job publishes the pre-built tarball, so move type-checking into `scripts.build`. Set `ignore-scripts: true` to disable script execution entirely.
- **Single-package npm/pnpm only** — workspaces are rejected ([#208](https://github.com/TomHennen/wrangle/issues/208)), and so are Yarn lockfiles.
- **The SBOM covers the source tree, not the tarball contents** — the L3 attestation covers the exact `.tgz` bytes regardless.
- **`release-events`** (default: `non-pull-request`; the example sets `tag-only`) controls when release-time actions run and what `should-release` reports — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating".
- **`pull_request_target` can't trigger this workflow** — that trigger (and `workflow_run` chained from it) is a common exploit vector, so wrangle blocks both at startup.
- **Workflow outputs** are documented in [`build_and_publish_npm.yml`](../../../.github/workflows/build_and_publish_npm.yml) itself.
- **Enable Dependabot too** — copy [`dependabot.yml`](../../../gh_workflow_examples/dependabot.yml) to `.github/` and uncomment the `npm` entry. Its `github-actions` entry also keeps your `uses: TomHennen/wrangle/...` pin current.

## Verifying what you shipped

Downstream users verify the released tarball with one command. Download the tarball and its `<tarball>.intoto.jsonl` bundle from the release (it carries the tarball's VSA; ampel self-selects the one matching `--subject`), then ([ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0):

```bash
ampel verify --subject <tarball> \
  --policy git+https://github.com/TomHennen/wrangle@v0.3.1#policies/wrangle-vsa-consumer-v1.hjson \
  --collector jsonl:<tarball>.intoto.jsonl \
  --context expectedResourceUri:pkg:npm/<name>@<version> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

That single command checks — fail-closed — the signature, wrangle's signer identity, that the build ran in *your* repo, and that policy passed at SLSA Build L3. Scoped names go in the purl verbatim (`pkg:npm/@scope/pkg@1.2.3`). No ampel? See the [artifact verification guide](../../../docs/verifying_artifacts.md) for an equivalent cosign recipe, npm's registry-side check, and the full trust model.

The VSA is also posted to your repo's GitHub attestation store, so consumers can fetch it by digest with no download via ampel's `--collector github:<your-org>/<your-repo>` — see the [by-digest path](../../../docs/verifying_artifacts.md#by-digest-from-the-github-attestation-store).

## Further reading

- [`SPEC.md`](./SPEC.md) — design rationale: attestation model (L2 vs L3), tool choices.
- [`docs/verifying_artifacts.md`](../../../docs/verifying_artifacts.md) — consumer verification: ampel, cosign, `gh attestation verify`, `npm audit signatures`.
- [`docs/REQUIREMENTS_MAPPING.md`](../../../docs/REQUIREMENTS_MAPPING.md) — the SLSA Build L3 requirements mapping, including the per-surface cache analysis (npm vs pnpm).
- [npm Trusted Publishing](https://docs.npmjs.com/trusted-publishers/) — the underlying publish mechanism.
