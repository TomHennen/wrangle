# Wrangle Build npm

Build an npm or pnpm package (`npm pack` / `pnpm pack`), run tests, generate an SBOM, and produce SLSA L3 provenance. Package manager is detected from the lockfile (`package-lock.json` / `npm-shrinkwrap.json` → npm; `pnpm-lock.yaml` → pnpm). Publishes to npmjs.org via Trusted Publishing — the publish job lives in the caller workflow because npm's OIDC token must come from the caller's workflow filename, not a reusable workflow ([npm/documentation#1755](https://github.com/npm/documentation/issues/1755)).

## Quick-start

Most adopters want the reusable workflow:

```yaml
jobs:
  build:
    permissions:
      contents: write   # SLSA generator's upload-assets job
      id-token: write   # OIDC for Sigstore signing
      actions: read     # SLSA generator detects the GitHub Actions environment
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml@v0.2.0
    with:
      path: "."
```

Then add a publish job — see [`gh_workflow_examples/build_npm.yml`](../../../gh_workflow_examples/build_npm.yml) for the template. Pair with [`check_source_change.yml`](../../../actions/scan/README.md) for source-side coverage.

Or use the composite directly (build + test + SBOM only; you wire your own provenance and publish):

```yaml
- uses: TomHennen/wrangle/build/actions/npm@v0.2.0
  with:
    path: "."
```

This README documents shipped behavior. For the full design (attestation model, step sequence), see [`SPEC.md`](./SPEC.md); workspaces support is designed in [`WORKSPACES_PHASE_1.md`](./WORKSPACES_PHASE_1.md) but not yet implemented.

## Before first use

Complete in order — step 1 requires an `NPM_TOKEN` that step 3 then disallows.

1. **Bootstrap v0.0.1 manually.** npm Trusted Publishing can't publish a package's *first* version ([npm/cli#8544](https://github.com/npm/cli/issues/8544)). Run `npm publish` once from a maintainer's terminal with an `NPM_TOKEN`. Skip this and the first workflow run fails with a non-obvious "package not found".
2. **Configure the trusted publisher.** npmjs.com → your package → Settings → Trusted publishing. Pin: GitHub repo, workflow filename (`build_npm.yml`), optionally an environment.
3. **Enable "Require two-factor authentication and disallow tokens"** on the package (Settings → Publishing access). This blocks all classic / granular publish tokens, leaving Trusted Publishing's OIDC flow as the only publish path. **Without this, a stolen token bypasses your CI entirely** — the attack vector behind the May 2026 mistralai / guardrails-ai and December 2024 ultralytics compromises, where attackers shipped malware by pushing directly to the registry, never triggering the legitimate workflow. After enabling, revoke the bootstrap `NPM_TOKEN`.

## Build Track level

Consumed through `build_and_publish_npm.yml`, the build meets **SLSA v1.2 Build L3** for both the npm and pnpm sub-paths. Two conditions narrow the claim:

- **Reusable consumption only.** Calling the composite directly forfeits the build-vs-sign job separation — **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation L3 assumes.

The npm sub-path keeps dependency caching on: `npm ci` re-verifies every cached tarball's `integrity` against `package-lock.json`, so the cache cannot poison the attested output. The pnpm sub-path uses no cross-build cache — pnpm-store doesn't re-verify content-addressed paths at install time (the May 2026 Mini Shai-Hulud / TanStack cache-poisoning vector; see [#205](https://github.com/TomHennen/wrangle/issues/205)). Full analysis: [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md).

The build-platform L3 claim is distinct from — and additional to — the SLSA L2 in-CLI attestation that `npm publish --provenance` writes into the npm registry slot. Both attestations share the Sigstore Public Good Instance; the L2-vs-L3 distinction is builder isolation, not crypto root.

## What this action does

- Validates `package.json` + a supported lockfile (`package-lock.json`, `npm-shrinkwrap.json`, or `pnpm-lock.yaml`). Yarn is rejected — support is a follow-on. Both an npm-style lockfile AND `pnpm-lock.yaml` together is rejected as ambiguous.
- Installs Node.js via `actions/setup-node`. Version resolution: `node-version` input → `.nvmrc` → `package.json` `engines.node` → wrangle-default LTS (Node 22). Set one of the first three explicitly if you care about a specific version.
- For pnpm: enables [Corepack](https://nodejs.org/api/corepack.html) and uses `package.json`'s `packageManager` field if set. **Set `packageManager` for deterministic builds.**
- Installs (`npm ci` or `pnpm install --frozen-lockfile`).
- Runs `scripts.build` if present (skipped if absent).
- Runs tests if `scripts.test` is non-default (the npm-default `"echo \"Error: no test specified\" && exit 1"` is detected and skipped).
- Packs to `dist/` via `npm pack` or `pnpm pack`.
- Generates an SPDX SBOM via [`syft`](https://github.com/anchore/syft) (Cosign-keyless-verified install) over the source tree.
- Computes SHA-256 hashes for `slsa-github-generator`'s `base64-subjects`.

## Outputs from the reusable workflow

- `dist-artifact-name` — workflow-artifact name for the tarball.
- `tarball` — `.tgz` filename relative to the dist artifact root. Scoped packages produce `scope-name-version.tgz`.
- `provenance-artifact-name` — workflow-artifact name for the SLSA provenance (`npm-<shortname>.intoto.jsonl`; empty when `should-release` is false).
- `metadata-artifact-name` — workflow-artifact name for the SBOM (`npm-metadata-<shortname>`).
- `should-release` — `"true"` if the event matches `release-events`. Your publish job MUST gate on this.
- `hashes`, `version`.

## Controlling when releases happen

`release-events` controls which events produce SLSA provenance. Shorthands: `non-pull-request` (default), `tag-only`, `main-and-tags`. A comma-separated `github.event_name` list is also accepted — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating".

> **Required wiring.** Your publish job MUST also gate on `should-release` — wrangle can't enforce this because publish lives in your workflow (npm's OIDC constraint). The canonical shape:
>
> ```yaml
> publish:
>   if: ${{ needs.build.outputs.should-release == 'true' }}
>   needs: [build]
> ```
>
> Without the gate, publish runs on every non-PR event regardless of `release-events`.

## SLSA provenance verification (default-on, opt-out)

The reusable workflow re-fetches the dist and verifies it against the L3 provenance before declaring success — failure blocks your publish job via `needs:`. This closes the wrangle→caller-publish handoff (the caller→registry segment is bound by Trusted Publishing's `workflow_ref` claim, which npm validates at upload time). Opt out with `verify-provenance: false` if you maintain a custom verification flow.

## Verifying after install (downstream consumers)

Two complementary verification paths, different roots of trust:

**npm's L2 in-CLI attestation (against the registry).** Default consumer flow:

```bash
npm install <pkg>@<version>
npm audit signatures
# Expected: "<pkg>@<version> ... has a verified attestation"
```

Proves the bundle was published from the expected GitHub repo + workflow.

> **Known limitation.** `npm install` doesn't run `npm audit signatures` by default; consumers must opt in. Until verification is the default, the load-bearing check is npm's upload-time `workflow_ref` validation — but that only holds when "Require two-factor authentication and disallow tokens" is enabled on the package (see "Before first use"), since a stolen token bypasses it entirely.

**Wrangle's L3 SLSA provenance (against the GitHub release).** Non-falsifiable because the generator runs in an isolated reusable workflow. Attached to the GitHub release on tag pushes:

```bash
curl -LO https://github.com/<owner>/<repo>/releases/download/<tag>/<scope>-<name>-<version>.tgz
curl -LO https://github.com/<owner>/<repo>/releases/download/<tag>/npm-<shortname>.intoto.jsonl

slsa-verifier verify-artifact \
  --provenance-path npm-<shortname>.intoto.jsonl \
  --source-uri github.com/<owner>/<repo> \
  <scope>-<name>-<version>.tgz
```

> **Tag-push only.** On non-tag publishes the provenance lives only as a 90-day workflow artifact, not retrievable by external consumers. Same constraint applies to private npm registries: the L3 bundle lives at the GitHub release, not the private registry. [#181](https://github.com/TomHennen/wrangle/issues/181) tracks moving to a single bundled `multiple.intoto.jsonl` at the release layer.

## Lifecycle hooks

By default, hooks fire normally — `prepare`, `prepack`, `postpack`, and dependency `install` hooks run just as they would locally. The L3 attestation binds to "what wrangle built from this commit's source + lockfile," which is what source-control review already governs (a malicious `package.json` script is the same threat surface as malicious code in `src/`).

- **`prepack` / `prepare` run** during wrangle's pipeline; whatever they produce is what wrangle hashes and attests.
- **`prepublishOnly` does NOT fire** — it only runs when `npm publish` is invoked against a directory, not against a pre-built tarball. Move type-checking work into `scripts.build`.
- **Tarball-direct publish is intentional.** Your publish job runs `npm publish <packed.tgz>`, so the bytes wrangle hashes are exactly the bytes consumers download.

**Opt-in hardening.** Set `ignore-scripts: true` for "source bytes only, no script execution": `--ignore-scripts` on install + pack, and `npm run build` / `npm test` are skipped outright. Default off because common ecosystem tools (husky, prebuild-install) rely on these hooks.

## Caching

- **npm path** enables [`setup-node`'s `cache: 'npm'`](https://github.com/actions/setup-node#caching-global-packages-data), keyed on the lockfile. Safe because `npm ci` re-validates each cached tarball's `integrity` field on install.
- **pnpm path** does NOT enable caching. pnpm-store doesn't re-verify content-addressed paths at install — see Build Track level above and [#205](https://github.com/TomHennen/wrangle/issues/205).

## v0.2 status

- **Supported:** npm and pnpm. Yarn is a follow-on.
- **Single-package only.** Workspaces (`package.json` with a `workspaces` field, or pack producing >1 `.tgz`) is rejected. Tracked in [#208](https://github.com/TomHennen/wrangle/issues/208).
- **SBOM scope is the source tree, not the tarball.** Wrangle runs `syft dir:<path>`. If `package.json`'s `files` field restricts what ships, the SBOM may list components not in the `.tgz`; conversely, native binaries `prebuild-install` fetches at consumer install time aren't in source and aren't in the SBOM. Layer binary scanners (Trivy, Grype) against installed `node_modules/` if you need that coverage. The L3 attestation covers the exact `.tgz` bytes regardless.
