# Wrangle Build npm

Build an npm or pnpm package (`npm pack` / `pnpm pack`), run tests, generate an SBOM, and produce SLSA L3 provenance. Publish goes to npmjs.org via Trusted Publishing.

Package manager is detected from the lockfile: `package-lock.json` or `npm-shrinkwrap.json` selects npm; `pnpm-lock.yaml` selects pnpm.

The publish job lives in your own workflow — not in a wrangle reusable workflow — because npm's OIDC token must come from the caller's workflow filename ([npm/documentation#1755](https://github.com/npm/documentation/issues/1755)).

## Quick-start

Wrangle publishes via [npm Trusted Publishing](https://docs.npmjs.com/trusted-publishers/) — no `NPM_TOKEN` lives in your repo. You'll do a one-time setup on npmjs.com first; see [Before first use](#before-first-use). Then:

Copy [`gh_workflow_examples/build_npm.yml`](../../../gh_workflow_examples/build_npm.yml) into your repo at `.github/workflows/`. The example wires the required permissions (`attestations: write` so wrangle's attest job can write the GitHub-issued provenance, `id-token: write` for Sigstore keyless signing, `contents: write` so the VSA job can attach the VSA to the release on tag pushes) and includes the publish job. Most adopters only need to set the `path` input.

Pair with [source scan](../../../actions/scan/README.md) — build hardens *how* your artifact is produced; source scan covers *what was checked into the repo you're building from*.

For the composite-only path (build + test + SBOM; you wire your own provenance and publish), use `TomHennen/wrangle/build/actions/npm@v0.2.0` as a step.

This README documents shipped behavior. For the full design (attestation model, step sequence), see [`SPEC.md`](./SPEC.md); workspaces support is designed in [`WORKSPACES_PHASE_1.md`](./WORKSPACES_PHASE_1.md) but not yet implemented.

## Before first use

Complete in order. Step 1 only applies to brand-new packages; migrating an existing package skips straight to step 2.

1. **Brand-new package — bootstrap the first version manually.** npm Trusted Publishing can't publish a package's *first* version ([npm/cli#8544](https://github.com/npm/cli/issues/8544)) — unlike PyPI, npm has no "pending publisher" flow. Run `npm publish` once from a maintainer's terminal with an `NPM_TOKEN` to mint v0.0.1 (or whatever your initial version is). Skip this and the first workflow run fails with a non-obvious "package not found". (If you're migrating an already-published package, skip this step.)
2. **Configure the trusted publisher.** npmjs.com → your package → Settings → Trusted publishing. Pin: GitHub repo, workflow filename (`build_npm.yml`), optionally an environment.
3. **Enable "Require two-factor authentication and disallow tokens"** on the package (Settings → Publishing access). This blocks all classic / granular publish tokens, leaving Trusted Publishing's OIDC flow as the only publish path. **Without this, a stolen token bypasses your CI entirely** — the attack vector behind the May 2026 mistralai / guardrails-ai and December 2024 ultralytics compromises, where attackers shipped malware by pushing directly to the registry, never triggering the legitimate workflow. After enabling, revoke any token you used for step 1 (or any token migrating from your pre-Trusted-Publishing setup).

## Build Track level

Consumed through `build_and_publish_npm.yml`, the build meets **SLSA v1.2 Build L3** for both the npm and pnpm sub-paths if both of these conditions hold:

- **Reusable consumption only.** Calling the composite directly forfeits the build-vs-sign job separation — **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation L3 assumes.

The npm sub-path keeps dependency caching on: `npm ci` re-verifies every cached tarball's `integrity` against `package-lock.json`, so the cache cannot poison the attested output. The pnpm sub-path uses no cross-build cache — pnpm-store doesn't re-verify content-addressed paths at install time (the May 2026 Mini Shai-Hulud / TanStack cache-poisoning vector; see [#205](https://github.com/TomHennen/wrangle/issues/205)). Full analysis: [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md).

The build-platform L3 claim is distinct from — and additional to — the SLSA L2 in-CLI attestation that `npm publish --provenance` writes into the npm registry slot. Both attestations share the Sigstore Public Good Instance; the L2-vs-L3 distinction is that npm's in-CLI publish path lacks builder isolation, wrangle's reusable workflow does not.

## What this action does

- Validates `package.json` + a supported lockfile (`package-lock.json`, `npm-shrinkwrap.json`, or `pnpm-lock.yaml`). Yarn is rejected — support is a follow-on. Both an npm-style lockfile AND `pnpm-lock.yaml` together is rejected as ambiguous.
- Installs Node.js via `actions/setup-node`. Version resolution: `node-version` input → `.nvmrc` → `package.json` `engines.node` → wrangle-default LTS (Node 22). Set one of the first three explicitly if you care about a specific version.
- For pnpm: enables [Corepack](https://nodejs.org/api/corepack.html) and uses `package.json`'s `packageManager` field if set. **Set `packageManager` for deterministic builds.**
- Installs (`npm ci` or `pnpm install --frozen-lockfile`).
- Runs `scripts.build` if present (skipped if absent).
- Runs tests if `scripts.test` is non-default (the npm-default `"echo \"Error: no test specified\" && exit 1"` is detected and skipped).
- Packs to `dist/` via `npm pack` or `pnpm pack`.
- Generates an SPDX SBOM via [`syft`](https://github.com/anchore/syft) (Cosign-keyless-verified install) over the source tree.
- Computes SHA-256 hashes of the built artifacts, which the reusable workflow's `attest` job feeds to `actions/attest-build-provenance` as the provenance subjects.

## Outputs from the reusable workflow

- `dist-artifact-name` — workflow-artifact name for the tarball.
- `tarball` — `.tgz` filename relative to the dist artifact root. Scoped packages produce `scope-name-version.tgz`.
- `provenance-artifact-name` — workflow-artifact name for the SLSA provenance bundle (`npm-provenance-bundle-<shortname>`, a Sigstore bundle covering all dist subjects; empty when `should-release` is false).
- `metadata-artifact-name` — workflow-artifact name for the SBOM (`npm-metadata-<shortname>`).
- `should-release` — `"true"` if the package should be released. Today that means the event matched `release-events`; future versions may apply additional checks, so treat the output as the source of truth rather than re-evaluating `release-events` yourself. Your publish job MUST gate on this (see below).
- `hashes`, `version`.

## Controlling when releases happen

`release-events` controls which events trigger release-time actions: SLSA provenance generation, verification, and — via the `should-release` output — your downstream publish job. Accepted values:

- `non-pull-request` (default) — every event except `pull_request`.
- `tag-only` — only `push` events to `refs/tags/*`.
- `main-and-tags` — `push` to `refs/heads/main` or `refs/tags/*`.
- A comma-separated `github.event_name` list (e.g., `push,workflow_dispatch`).

See [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating" for the full vocabulary.

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

The reusable workflow re-fetches the dist and verifies it against the L3 provenance before declaring success (`gh attestation verify --signer-workflow`, fail-closed unless wrangle's reusable workflow signed the bundle) — failure blocks your publish job via `needs:`. This closes the wrangle→caller-publish handoff (the caller→registry segment is bound by Trusted Publishing's `workflow_ref` claim, which npm validates at upload time). Opt out with `verify-provenance: false` if you maintain a custom verification flow.

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

**Wrangle's L3 SLSA provenance (against GitHub's attestation store).** Non-falsifiable because the attest step runs inside wrangle's isolated reusable workflow, which is named as the provenance's `builder.id` and as the Sigstore signing identity. The provenance is stored in GitHub's attestation store for your repo (not attached to the release), so a consumer verifies the downloaded tarball against it with `gh attestation verify`:

```bash
curl -LO https://github.com/<owner>/<repo>/releases/download/<tag>/<scope>-<name>-<version>.tgz

gh attestation verify <scope>-<name>-<version>.tgz \
  --repo <owner>/<repo> \
  --signer-workflow TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml
```

`--signer-workflow` is the binding: it fails closed unless wrangle's reusable workflow signed the provenance. `gh` fetches the attestation from GitHub's store by the tarball's digest, so no separate provenance file download is needed.

### Verifying the VSA

On tag pushes wrangle attaches a signed SLSA Verification Summary Attestation (VSA) per tarball — `<tarball>.intoto.jsonl` — to the GitHub release, recording that the build provenance passed the `wrangle-provenance-npm-v1` PolicySet. A consumer trusts that single signed VSA instead of re-running the policy engine. It is keyless-signed by **wrangle's** reusable workflow (`build_and_publish_npm.yml`), not your own. Its `resourceUri` is the npm purl `pkg:npm/<name>@<version>` (scoped names verbatim, e.g. `pkg:npm/@scope/pkg@1.2.3`) — pin that exact string.

Grab the tarball and its VSA from the release:

```bash
curl -LO https://github.com/<owner>/<repo>/releases/download/<tag>/<tarball>
curl -LO https://github.com/<owner>/<repo>/releases/download/<tag>/<tarball>.intoto.jsonl
```

**Recommended — `cosign verify-blob-attestation` + `jq`.** This is the complete check: cosign confirms the signature, the signer identity (wrangle's reusable workflow), **your origin repository** — `--certificate-github-workflow-repository`, the binding that proves *which repo* built the artifact — and that the tarball's hash matches the VSA subject. cosign doesn't read predicate fields, so a `jq` decode covers `verificationResult` / `resourceUri` / `verifiedLevels`:

```bash
cosign verify-blob-attestation --bundle <tarball>.intoto.jsonl --new-bundle-format \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_npm\.yml@refs/tags/v' \
  --certificate-github-workflow-repository <your-org>/<your-repo> \
  --type https://slsa.dev/verification_summary/v1 \
  <tarball>

payload="$(jq -r '.dsseEnvelope.payload' <tarball>.intoto.jsonl | base64 -d)"
jq -e '.predicate.verificationResult == "PASSED"' <<<"$payload"
jq -e '.predicate.resourceUri == "pkg:npm/<name>@<version>"' <<<"$payload"
jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3")' <<<"$payload"
```

`--type` must be the full URI `https://slsa.dev/verification_summary/v1` — cosign rejects the `slsaverificationsummary` alias.

**One command, but no repo binding — `ampel verify` (not recommended yet).** ampel can check the VSA against a wrangle-hosted consumer policy in a single command, but ampel (v1.2.1) matches only the signing cert's issuer + SAN — **not** its source-repository extension — so it cannot bind the origin repo and would accept a wrangle-signed VSA built in a *different* repo. That gap is too big to recommend it as your check today; use the cosign command above. ampel may return as a one-command option once the binding is fixed — [#321](https://github.com/TomHennen/wrangle/issues/321).

> **`slsa-verifier verify-vsa` is not usable here.** It only verifies *key-signed* VSAs (it requires `--public-key-path`); wrangle's VSAs are keyless (Fulcio/Sigstore), so there is no identity flag to pass. Tracked under the [Attestation trust gaps](../../../README.md) section / [#317](https://github.com/TomHennen/wrangle/issues/317).

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
