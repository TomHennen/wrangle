# Wrangle Build npm

Build an npm or pnpm package, run your tests, generate an SBOM, produce SLSA Build L3 provenance, and publish to npmjs.org via Trusted Publishing — no `NPM_TOKEN` in your repo, and a signed VSA your users can verify with one command. The package manager is detected from your lockfile: `package-lock.json` / `npm-shrinkwrap.json` selects npm, `pnpm-lock.yaml` selects pnpm.

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
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml@v0.2.0
    with:
      path: "."
      release-events: tag-only   # only tag pushes publish

  publish:
    # ... see the example: gates on should-release, verifies, then publishes
```

## Before first use

Complete in order; step 1 only applies to brand-new packages.

1. **Brand-new package: bootstrap the first version manually.** npm Trusted Publishing can't publish a package's *first* version ([npm/cli#8544](https://github.com/npm/cli/issues/8544)) — there is no PyPI-style "pending publisher" flow. Run `npm publish` once from a maintainer's terminal to mint the initial version; skipping this makes the first workflow run fail with a non-obvious "package not found".
2. **Configure the trusted publisher** — npmjs.com → your package → Settings → Trusted publishing. Pin your repo and the workflow filename (`build_npm.yml`).
3. **Enable "Require two-factor authentication and disallow tokens"** (Settings → Publishing access), leaving Trusted Publishing as the only publish path. Without it, a stolen token can push to the registry without ever touching your CI. Then revoke any token used in step 1.

## What you get

- **npm or pnpm, auto-detected** from the lockfile; for pnpm, Corepack honors `package.json`'s `packageManager` field — set it for deterministic builds.
- **Your scripts run as usual** — `scripts.build` if present, `scripts.test` unless it's npm's default placeholder, then `npm pack` / `pnpm pack`.
- **Source scan** built in — vulnerable dependencies (OSV), unsafe workflow patterns (Zizmor), and more ([details](../../../actions/scan/README.md)); a load-bearing finding blocks publish.
- **An SPDX SBOM**, uploaded as a workflow artifact.
- **SLSA Build L3 provenance** ([the conditions behind the claim](../../../docs/SLSA_L3_AUDIT.md)), in addition to the L2 attestation `npm publish --provenance` writes to the registry.
- **A signed VSA** attached to the release on tag pushes, so downstream users can verify the tarball with one command.

## Your publish job

Publishing happens in your workflow, so two things there are load-bearing — both already wired in the example:

1. **Gate on `should-release`**, so you publish only on release events (wrangle can't enforce this from inside the reusable workflow):

   ```yaml
   publish:
     if: ${{ needs.build.outputs.should-release == 'true' }}
     needs: [build]
   ```

2. **Verify before you publish** — run wrangle's [`verify-vsa`](../../../actions/verify-vsa/README.md) action between `download-artifact` and `npm publish`, so the exact bytes leaving the runner are the bytes that passed wrangle's policy:

   ```yaml
   - uses: TomHennen/wrangle/actions/verify-vsa@v0.2.0
     with:
       path: dist/
       signer-workflow: TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml
   ```

Skip the gate and you publish on every non-PR event; skip verify-vsa and you may publish bytes wrangle's policy never blessed.

## Good to know

- **Node version resolution**: `node-version` input → `.nvmrc` → `package.json` `engines.node` → a wrangle-default LTS. Set one of the first three if you care about a specific version.
- **Lifecycle hooks fire normally** (`prepare`, `prepack`, `postpack`, dependency `install` hooks). `prepublishOnly` does NOT — your publish job publishes the pre-built tarball, so move type-checking into `scripts.build`. Set `ignore-scripts: true` to disable script execution entirely.
- **Single-package npm/pnpm only** — workspaces are rejected ([#208](https://github.com/TomHennen/wrangle/issues/208)), and so are Yarn lockfiles.
- **The SBOM covers the source tree, not the tarball contents** — the L3 attestation covers the exact `.tgz` bytes regardless.
- **`release-events`** (default: `non-pull-request`; the example sets `tag-only`) controls when release-time actions run and what `should-release` reports — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating".
- **`pull_request_target` can't trigger this workflow** — wrangle refuses it at startup (likewise `workflow_run` chained from it); those triggers hand fork PRs elevated access.
- **Workflow outputs** are documented in [`build_and_publish_npm.yml`](../../../.github/workflows/build_and_publish_npm.yml) itself.

## Verifying what you shipped

Downstream users verify the released tarball with one command. Download the tarball and its VSA (`<tarball>.intoto.jsonl`) from the release, then ([ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0):

```bash
ampel verify --subject <tarball> \
  --policy git+https://github.com/TomHennen/wrangle@v0.2.0#policies/wrangle-vsa-consumer-v1.hjson \
  --attestation <tarball>.intoto.jsonl \
  --context expectedResourceUri:pkg:npm/<name>@<version> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

That single command checks — fail-closed — the signature, wrangle's signer identity, that the build ran in *your* repo, and that policy passed at SLSA Build L3. Scoped names go in the purl verbatim (`pkg:npm/@scope/pkg@1.2.3`). No ampel? See the [artifact verification guide](../../../docs/verifying_artifacts.md) for an equivalent cosign recipe, npm's registry-side check, and the full trust model.

## Further reading

- [`SPEC.md`](./SPEC.md) — design rationale: attestation model (L2 vs L3), tool choices.
- [`docs/verifying_artifacts.md`](../../../docs/verifying_artifacts.md) — consumer verification: ampel, cosign, `gh attestation verify`, `npm audit signatures`.
- [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) — the conditions behind the Build L3 claim, including the npm-vs-pnpm cache analysis.
- [npm Trusted Publishing](https://docs.npmjs.com/trusted-publishers/) — the underlying publish mechanism.
