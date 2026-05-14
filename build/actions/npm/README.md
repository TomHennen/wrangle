# Wrangle Build npm

Build an npm or pnpm package (tarball via `npm pack` or `pnpm pack`), run tests, generate an SBOM, and produce SLSA L3 build provenance via `slsa-github-generator`. Package manager is detected from the lockfile (`package-lock.json` / `npm-shrinkwrap.json` → npm; `pnpm-lock.yaml` → pnpm). The publish step itself runs in the adopter's own workflow because npm Trusted Publishing's OIDC token must come from the caller's workflow filename, not a reusable workflow ([npm/documentation#1755](https://github.com/npm/documentation/issues/1755)).

> **Note:** This README documents *currently-shipped* behavior. For the full design — architecture, attestation model, full step sequence — see [`SPEC.md`](./SPEC.md). For npm workspaces support (multi-package monorepos), see [`WORKSPACES_PHASE_1.md`](./WORKSPACES_PHASE_1.md) — design only; not yet implemented.

## Recommended companion: source scan

This action hardens *how* your artifact is produced. It does NOT scan your source — vulnerable deps in your lockfile, dangerous workflow triggers, or missing branch protection still slip through and would be faithfully L3-attested by wrangle as legitimately built. Pair this with wrangle's source-scan workflow ([`actions/scan/README.md`](../../../actions/scan/README.md)) to close that gap on every PR and push. The May 2026 Mini Shai-Hulud compromise of TanStack/router is the most recent example of why this matters — the build side wasn't the vulnerability; the source side was.

## Before first use

Complete these in order — step 1's bootstrap publish requires an `NPM_TOKEN`, which step 3 disallows.

1. **Bootstrap the package's first version manually.** npm Trusted Publishing cannot publish a package's *first* version ([npm/cli#8544](https://github.com/npm/cli/issues/8544)). For a brand-new package, run `npm publish` once from a maintainer's terminal with an `NPM_TOKEN` to mint v0.0.1 (or whatever the initial version is). After that, every subsequent version goes through the automated path. Skip this step and your first run of the workflow will fail with a non-obvious "package not found" error from the registry.

2. **Configure the trusted publisher.** On npmjs.com → your package → Settings → Trusted publishing, pin: GitHub repo, workflow filename (`build_npm.yml`), and optionally an environment.

3. **Enable npm's "Require two-factor authentication and disallow tokens" setting on the package.** On npmjs.com → your package → Settings → Publishing access, select **"Require two-factor authentication and disallow tokens (recommended)"**. This is npm's equivalent of PyPI's "disable token uploads": it blocks all classic / granular publish tokens from being used on the package, leaving Trusted Publishing's OIDC flow as the only publish path (npm's own UI confirms: "All publishing access options above are compatible with OIDC trusted publishers"). **Without this**, a stolen or leftover token bypasses your CI entirely — the attack vector behind the May 2026 `mistralai` / `guardrails-ai` PyPI compromise and the December 2024 ultralytics compromise (both shipped malware to the registry by pushing directly, never triggering the legitimate workflow, even though Trusted Publishing was configured on the affected projects). After enabling the setting, revoke the bootstrap NPM_TOKEN you used in step 1 at npmjs.com → account settings → access tokens — defense in depth.

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

- Validates that `package.json` and a supported lockfile (`package-lock.json`, `npm-shrinkwrap.json`, or `pnpm-lock.yaml`) exist. Yarn (`yarn.lock`) is rejected — Yarn support is a follow-on. If both an npm-style lockfile AND `pnpm-lock.yaml` are present, the action rejects the ambiguous state.
- Installs Node.js via `actions/setup-node`. Version resolution order: the `node-version` input, then `.nvmrc`, then `package.json`'s `engines.node`, then a wrangle-default LTS (currently Node 22). Adopters who care about a specific version should set one of the first three explicitly rather than rely on the fallback.
- For pnpm projects: enables [Corepack](https://nodejs.org/api/corepack.html) (bundled with Node 16.10+) to provide pnpm on the runner. Corepack uses the version pinned by `package.json`'s `packageManager` field if set, otherwise its bundled default. **Adopters who want deterministic builds should set `packageManager`** — that's the modern ecosystem-standard pin for pnpm and Yarn versions.
- Installs dependencies with `npm ci` (lockfile-faithful, fails on lockfile drift) or `pnpm install --frozen-lockfile` (the pnpm equivalent).
- Runs the project's build script (`npm run build` or `pnpm run build`) if `package.json` declares a `scripts.build` entry. Skipped if absent.
- Runs tests (`npm test` or `pnpm test`) if `package.json` declares a non-default `scripts.test` entry (the npm-default `"echo \"Error: no test specified\" && exit 1"` is detected and skipped).
- Produces the package tarball via `npm pack` or `pnpm pack`, written to `dist/`.
- Generates an SPDX SBOM via [`syft`](https://github.com/anchore/syft) (Cosign-keyless-verified install, same tool python uses) over the project source tree.
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

**End-to-end coverage.** Wrangle's `verify` job closes the wrangle→caller-publish handoff: it re-fetches the dist artifact and confirms it matches wrangle's L3 provenance before letting the publish step run. The caller→registry segment is bound by Trusted Publishing's OIDC `workflow_ref` claim, which the npm registry validates against the publisher's registered workflow filename. Consumers verifying the L2 attestation get end-to-end coverage by checking that `workflow_ref` matches the expected caller workflow path.

## Verifying after install (downstream consumers)

Your package's consumers can verify it two complementary ways. Each answers a different question, and they trust different roots.

### npm's L2 in-CLI attestation (against the registry)

`npm audit signatures` reports whether the registry-served bundle verifies against the package's published Sigstore attestation. This is the default consumer flow.

```bash
npm install <pkg>@<version>
npm audit signatures
# Expected output: "<pkg>@<version> ... has a verified attestation"
```

This proves the bundle was published from the expected GitHub repo + workflow, but does **not** independently attest to the build environment beyond what the npm CLI's in-process signing captures (SLSA L2).

> **Known limitation.** `npm install` does NOT run `npm audit signatures` by default. Consumers who care about attestation verification must opt in by running `npm audit signatures` as a separate step. Until verification is the default, the load-bearing check is the registry-side `workflow_ref` validation at *upload* time — but that check is only meaningful when "Require two-factor authentication and disallow tokens" is enabled on the package (see "Before first use" above), since a stolen token bypasses the workflow-identity binding entirely.

### Wrangle's L3 SLSA provenance (against the GitHub release)

For tag-pushed releases, wrangle attaches the L3 bundle as a release asset. SLSA provenance is non-falsifiable because the generator runs in an isolated reusable workflow.

```bash
# Download tarball + provenance from the GitHub release
curl -LO https://github.com/<owner>/<repo>/releases/download/<tag>/<scope>-<name>-<version>.tgz
curl -LO https://github.com/<owner>/<repo>/releases/download/<tag>/npm-<shortname>.intoto.jsonl

slsa-verifier verify-artifact \
  --provenance-path npm-<shortname>.intoto.jsonl \
  --source-uri github.com/<owner>/<repo> \
  <scope>-<name>-<version>.tgz
```

> **Important limitation.** Provenance is **only** in the GitHub release on tag pushes. On non-tag publishes (e.g., `workflow_dispatch` from a branch) the provenance lives only as a 90-day workflow artifact and is not retrievable by external consumers. Adopters whose workflows don't push tags should publicize how to obtain provenance — wrangle's convention is "tag pushes attach provenance to the release; non-tag publishes don't have consumer-retrievable provenance." Adopters publishing to private npm registries (Artifactory, etc.) face the same constraint: the L3 bundle lives at the GitHub release, not in the private registry.

[`#181`](https://github.com/TomHennen/wrangle/issues/181) tracks moving to a single bundled `multiple.intoto.jsonl` at the release/consumer layer; until that ships, use the per-build filename.

## Lifecycle hooks

Wrangle runs `npm ci` and `npm pack` (or `pnpm install --frozen-lockfile` and `pnpm pack`) against your project. By default, lifecycle hooks fire normally — `prepare`, `prepack`, `postpack`, and any `install` hooks in dependencies all run, just as they would for an adopter running these commands locally. The L3 attestation thus binds to "what wrangle built from this commit's source + lockfile" — which is what source-control review processes are already designed to govern. A malicious script in `package.json` or a pinned dev-dep is the same threat surface as malicious source code in `src/`: the source/lockfile is version-controlled, code review applies.

What this means concretely:

- **`prepack` and `prepare` run during wrangle's pipeline.** Whatever they produce is what wrangle hashes and attests. If you change `prepack`, the produced tarball — and thus the L3 attestation — changes accordingly. Same for transitive dev-deps' `prepare` scripts.
- **`prepublishOnly` does NOT fire.** It only runs when `npm publish` is invoked against a directory, not against a pre-built tarball. If you relied on it for type-checking, move the work into a regular `build` script — wrangle runs `npm run build` automatically when `package.json` declares one.
- **Tarball-direct publish is intentional.** Your publish job runs `npm publish <packed.tgz>`, so the bytes wrangle hashes are exactly the bytes consumers download. This is what makes wrangle's L3 attestation actionable.

**Opt-in hardening.** For adopters who want the stricter "source bytes only, no script execution" model, set `ignore-scripts: true` on the reusable workflow. When true, **nothing in your `package.json`'s `scripts` field runs**: `--ignore-scripts` is passed to both install and pack (suppressing `prepare`/`prepack`/`postpack`/`install` hooks, including in transitive dev-deps), AND `npm run build` / `npm test` (or pnpm equivalents) are skipped outright. The L3 attestation then binds to "what pack produces against this source with no script execution at all." Default is off because common ecosystem tools (husky's `prepare`, prebuild-install's `install`) rely on these hooks, and most projects expect their declared build/test to run; turning it on breaks those flows. If you need a finer-grained mode (suppress hooks but still run your own build), open an issue.

## Caching

Wrangle's npm path enables [`actions/setup-node`'s `cache: 'npm'`](https://github.com/actions/setup-node#caching-global-packages-data) keyed on the lockfile. This caches `~/.npm` (the registry tarball cache), which is safe because `npm ci` re-validates each cached tarball's `integrity` field against `package-lock.json` on every install — a poisoned cache that produces non-matching bytes is rejected before extraction.

Wrangle's **pnpm path does NOT enable setup-node caching.** pnpm-store stores extracted modules under content-addressed paths and does not re-verify content matches the path's claimed hash at install time. That's the cache-poisoning vector the May 2026 Mini Shai-Hulud / TanStack compromise exploited (see [issue #205](https://github.com/TomHennen/wrangle/issues/205) for the full analysis). For pnpm projects, wrangle accepts the cold-install overhead in exchange for closing that attack vector.

## v0.2 status

- **Supported package managers:** npm (`package-lock.json` / `npm-shrinkwrap.json`) and pnpm (`pnpm-lock.yaml`). Yarn is a follow-on.
- **Single-package only.** `package.json` with a `workspaces` field is rejected at validation; the action also errors out if pack produces more than one `.tgz`. Workspaces support (the N-tarball case) is tracked in [#208](https://github.com/TomHennen/wrangle/issues/208); design in [`WORKSPACES_PHASE_1.md`](./WORKSPACES_PHASE_1.md).
- **SBOM scope is the project source tree, not the tarball contents.** Wrangle runs `syft dir:<path>` over your source. If `package.json`'s `files` field restricts what `npm pack` ships, the SBOM lists components that aren't in the published `.tgz`. Conversely, bundled C/C++ binaries that `prebuild-install` fetches at consumer install time aren't in source — they don't appear in the SBOM either. Adopters who care about CVE coverage of compiled native portions SHOULD layer binary scanners (Trivy, Grype) against installed `node_modules/` in their own CI. The L3 attestation still covers the exact bytes of the npm `.tgz` regardless of what's inside it.
