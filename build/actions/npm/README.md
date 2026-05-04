# Wrangle Build npm

Build an npm package (tarball via `npm pack`), run tests, generate an SBOM, and produce SLSA L3 build provenance via `slsa-github-generator`. The publish step itself runs in the adopter's own workflow because npm Trusted Publishing's OIDC token must come from the caller's workflow filename, not a reusable workflow ([npm/documentation#1755](https://github.com/npm/documentation/issues/1755)).

> **Note:** This README documents *currently-shipped* behavior. For the full design — architecture, attestation model, full step sequence — see [`SPEC.md`](./SPEC.md).

## Before first use

**Bootstrap the package's first version manually.** npm Trusted Publishing cannot publish a package's *first* version ([npm/cli#8544](https://github.com/npm/cli/issues/8544)). For a brand-new package, run `npm publish` once from a maintainer's terminal with an `NPM_TOKEN` to mint v0.0.1 (or whatever the initial version is). After that, every subsequent version goes through the automated path. Skip this step and your first run of the workflow will fail with a non-obvious "package not found" error from the registry.

**Configure the trusted publisher.** On npmjs.com → your package → Settings → Trusted publishing, pin: GitHub repo, workflow filename (`build_npm.yml`), and optionally an environment.

## Quick-start

Two ways to adopt:

1. **Reusable workflow** — single `uses:` line in your CI. Runs the full pipeline (build → test → SBOM → SLSA L3 provenance → verify), with a publish job in your own workflow. This is what most adopters want.

   ```yaml
   jobs:
     build:
       permissions:
         # Required because wrangle's reusable workflow has a nested
         # provenance job that calls slsa-github-generator. GitHub
         # validates these permissions at workflow startup.
         contents: write   # SLSA generator's upload-assets job (write required even when upload-assets is false)
         id-token: write   # OIDC for Sigstore signing
         actions: read     # SLSA generator detects the GitHub Actions environment
       uses: TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml@v0.2.0
       with:
         path: "."
   ```

   Then add a publish job. See [`gh_workflow_examples/build_npm.yml`](../../../gh_workflow_examples/build_npm.yml) for the full template.

2. **Composite action** — drop into an existing workflow. Runs build + test + SBOM only; you wire in your own provenance and publish.

   ```yaml
   - uses: TomHennen/wrangle/build/actions/npm@v0.2.0
     with:
       path: "."
   ```

## What this action does

- Validates that `package.json` and a lockfile (`package-lock.json` or `npm-shrinkwrap.json`) exist. v0.1 supports npm only — pnpm and Yarn are follow-on.
- Installs Node.js via `actions/setup-node`. Version resolution order: the `node-version` input, then `.nvmrc`, then `package.json`'s `engines.node`, then a wrangle-default LTS (currently Node 22). Adopters who care about a specific version should set one of the first three explicitly rather than rely on the fallback.
- Installs dependencies with `npm ci` (lockfile-faithful, fails on lockfile drift).
- Runs `npm run build` if `package.json` declares a `scripts.build` entry. Skipped if absent.
- Runs `npm test` if `package.json` declares a non-default `scripts.test` entry (the npm-default `"echo \"Error: no test specified\" && exit 1"` is detected and skipped).
- Produces the package tarball via `npm pack`, written to `dist/`.
- Generates an SPDX SBOM via `npm sbom --sbom-format=spdx` (in-tree, npm 10+).
- Computes SHA-256 hashes of the tarball in the format `slsa-github-generator`'s `base64-subjects` input expects.

## Outputs from the reusable workflow

- `dist-artifact-name` — workflow-artifact name to download with `actions/download-artifact` to retrieve the built tarball.
- `tarball` — filename of the produced `.tgz` (relative to the dist artifact root). Scoped packages produce `scope-name-version.tgz` rather than `name-version.tgz`.
- `provenance-artifact-name` — workflow-artifact name for the SLSA provenance (empty when `should-release` is false). Format: `npm-<shortname>.intoto.jsonl` so multiple npm builds in one workflow don't collide.
- `metadata-artifact-name` — workflow-artifact name for the SBOM (`npm-metadata-<shortname>`).
- `should-release` — `"true"` if the current event matches `release-events`. Your publish job MUST gate on this.
- `hashes`, `version`.

## Controlling when releases happen

The `release-events` input controls which events produce SLSA provenance. Your publish job MUST also gate on `should-release` so wrangle's provenance gating and your publish gating stay in lockstep.

> **Required wiring.** Without the gate, your publish job runs on every non-PR event regardless of what you pass as `release-events`. The example workflow at [`gh_workflow_examples/build_npm.yml`](../../../gh_workflow_examples/build_npm.yml) shows the canonical shape:
>
> ```yaml
> publish:
>   if: ${{ needs.build.outputs.should-release == 'true' }}
>   needs: [build]
> ```
>
> Wrangle cannot enforce this from inside its reusable workflow — publish lives in your workflow due to npm Trusted Publishing's OIDC `workflow_ref` constraint. If you forget the gate, builds still succeed, provenance still respects `release-events`, but your publish runs more often than you intended.

`release-events` accepts: `non-pull-request` (default), `tag-only`, `main-and-tags`, or a comma-separated `github.event_name` list. See [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating" for the full vocabulary.

## SLSA provenance verification (default-on, opt-out)

Wrangle's reusable workflow generates non-falsifiable SLSA L3 build provenance via `slsa-github-generator`, **then verifies the just-built tarball against that provenance** before declaring the workflow successful. If verification fails, the workflow fails — and your publish job is blocked via standard `needs:` propagation. Pass `verify-provenance: false` to opt out of wrangle's verification (e.g., adopters with a custom verification flow).

## Two attestations, two surfaces

The npm pipeline produces two distinct attestations:

1. **Wrangle's L3 SLSA provenance**, generated by `slsa-github-generator` over the packed `.tgz` and uploaded as a separate workflow artifact (named per the reusable workflow's `provenance-artifact-name` output, format `npm-<shortname>.intoto.jsonl`). Verifiable offline by any consumer via `slsa-verifier verify-artifact` against the bundle. On tag pushes the bundle is also attached as a GitHub Release asset.
2. **npm's L2 in-CLI attestation**, populated by your publish job's `npm publish --provenance --access public` and stored in the npm registry's per-version slot. Verifiable by consumers via `npm audit signatures`.

Both bundles share the same Sigstore Public Good Instance (Fulcio, Rekor, TUF). The L2-vs-L3 distinction is builder isolation, not the cryptographic root of trust. See [`SPEC.md`](./SPEC.md) for the full attestation design.

## Lifecycle hooks

Wrangle runs `npm pack` to produce the tarball, and your publish job runs `npm publish <packed.tgz>`. Two consequences:

- **`prepublishOnly` does NOT fire.** It only runs when `npm publish` is invoked against a directory, not against a pre-built tarball. If you rely on `prepublishOnly` for type-checking or last-mile validation, move the work into a regular `build` script — wrangle runs `npm run build` automatically when `package.json` declares one.
- **`prepack` runs once, in wrangle's pipeline, against the source tree.** The tarball wrangle hashes is the exact tarball your publish job uploads. This is intentional: it's what makes wrangle's L3 attestation match what consumers download.

## v0.1 limitations

- npm only (pnpm and Yarn detection is follow-on).
- Single-package builds. Workspaces / monorepos that produce N tarballs from one build are not yet supported; the action errors out if `npm pack` produces more than one `.tgz`.
- Native modules: the npm `.tgz` is attested regardless of what's inside, but SBOM coverage of compiled C/C++ portions is partial. See [`SPEC.md`](./SPEC.md) "Awkward cases."
