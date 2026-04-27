# Wrangle npm Build Type — Phase 1 Research

**Status:** Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md). Recommends defaults for an eventual `build/actions/npm/` implementation. No `action.yml`, reusable workflow, example workflow, or test fixture exists yet.

## Overview

The npm ecosystem in 2026 is large, mature, and structurally well-suited to a wrangle build type: artifacts are file-based (`*.tgz`), the registry is centralized on npmjs.org, OIDC trusted publishing is GA, and `npm publish --provenance` already produces a Sigstore-signed SLSA L2 attestation by default. Most npm projects publish a single package from a single repo — workspace/monorepo cases exist but are a minority and have well-known coordination tools (changesets, Lerna, Nx).

**Operating model.** Wrangle owns the build hygiene **and its own L3 SLSA provenance**, just like the python and container build types. Concretely:

1. Wrangle invokes the build (`npm ci` → optional `npm run build` → optional `npm test` → `npm pack`).
2. Wrangle hashes the resulting `.tgz` and hands the hashes to `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml`. The generator emits an L3 Sigstore-signed in-toto bundle.
3. Wrangle stores the bundle in `metadata/npm/<shortname>/multiple.intoto.jsonl` per the existing unified metadata layout.
4. Wrangle verifies its own bundle via `slsa-verifier verify-artifact` between build and publish — closing the pre-publish verification gap.
5. The adopter's caller workflow publishes the hash-pinned `.tgz` with `npm publish --provenance`. That populates the npm registry's attestation slot with an additional **L2 in-CLI attestation** that `npm audit signatures` can verify.

The two attestations live in two different places and serve two different surfaces. Wrangle does not have to fight the npm registry's "one attestation slot per `(package, version)`" constraint, because wrangle's L3 lives in wrangle's metadata directory, not in the registry slot.

## Recommended defaults (the picks)

### Build tool — `npm` CLI

- **Pick:** `npm` (default).
- **Why:** `npm` ships with Node.js, is the dominant install/build manager, and the `package.json` lifecycle (`npm ci`, `npm run build`, `npm test`, `npm pack`, `npm publish`) is standardized across `npm`/`pnpm`/`yarn`. Building against `npm` first covers the largest adopter slice without precluding the others.
- **Variants:** `pnpm` and Yarn (Berry) are significant minorities. Detection rule keys off lockfiles:
  - `package-lock.json` → npm
  - `pnpm-lock.yaml` → pnpm
  - `yarn.lock` → Yarn
  - `package.json`'s `"packageManager"` field is the modern authoritative declaration ([Corepack](https://github.com/nodejs/corepack)).
- The detection rule is straightforward to add later. v0.1 ships npm; pnpm/yarn are follow-on.

### SBOM — `npm sbom --sbom-format=spdx`

- **Pick:** `npm sbom --sbom-format=spdx` (in-tree, npm 10+).
- **Why:** wrangle has standardized on **SPDX** ([unified metadata layout in `docs/SPEC.md`](../../../docs/SPEC.md)). `npm sbom` is in-tree, has no extra install/verify cost, and matches the registry's view of the dependency graph because it reads the same `package-lock.json` npm uses to resolve.
- **Caveats.**
  - The OWASP CycloneDX project lead has publicly criticized `npm sbom`'s **CycloneDX** output for spec-conformance lapses (registry integrity hashes placed on components, license-parsing dropouts). The equivalent claim for SPDX output is less prominent but conformance is contested rather than settled. Flagged in Open Questions.
  - For projects whose lockfile is `pnpm-lock.yaml` or `yarn.lock`, `npm sbom` requires a `package-lock.json` to be generated first (effectively `npm install --package-lock-only`). When pnpm/yarn variants land, an alternative path may be cleaner.
- **Alternatives for the future:** `@cyclonedx/cyclonedx-npm` (OWASP-maintained), `syft` (already in wrangle's tool inventory; SPDX-native; manager-agnostic), or `cdxgen` (multi-ecosystem). Worth re-evaluating if the SPDX-conformance question turns out to be material.

**Sources:** [npm-sbom docs](https://docs.npmjs.com/cli/v11/commands/npm-sbom/), [unified metadata layout](../../../docs/SPEC.md).

### Publish target — npmjs.org via Trusted Publishing

- **Pick:** **npmjs.org** as the only fully-supported publish-with-`--provenance` registry for v0.1. Adopters publishing to private registries (GitHub Packages, Verdaccio, Artifactory, Nexus) still get the wrangle pipeline including wrangle's own L3 bundle in `metadata/npm/<shortname>/`; they just don't get the registry-side L2 slot filled. See the attestation section below for why this matters less than it would have under the prior framing.
- **Why npmjs.org for `--provenance` specifically:** the in-CLI `--provenance` flow is wired to `registry.npmjs.org` (and GitLab); the Sigstore-bundle-to-registry handoff does not exist for self-hosted registries.

**Sources:** [npm Generating provenance statements](https://docs.npmjs.com/generating-provenance-statements/).

### Authentication — Trusted Publishing (OIDC)

- **Pick:** **npm Trusted Publishing** (GA [2025-07-31](https://github.blog/changelog/2025-07-31-npm-trusted-publishing-with-oidc-is-generally-available/)).
- **Mechanics.** Adopter configures a trusted publisher on npmjs.com → Packages → `<package>` → Settings → Trusted publishing, pinning a GitHub repo + workflow filename + optional environment. The publish workflow grants `id-token: write`, runs `actions/setup-node` with `registry-url: 'https://registry.npmjs.org'`, then runs `npm publish` with no `NODE_AUTH_TOKEN`. The npm CLI exchanges the GHA OIDC token for a short-lived publish credential. Provenance is auto-on under trusted publishing.
- **Caller-bound publish constraint.** The OIDC token's `workflow_ref` claim is bound to the **caller** workflow's filename (per the [npm Trusted Publishers Troubleshooting docs](https://docs.npmjs.com/trusted-publishers/)). A reusable workflow that calls `npm publish` for adopters does not satisfy this constraint — the `workflow_ref` is the caller's, not the reusable workflow's path. **This is the same caller-bound publish constraint as PyPI.** Implication: publish lives in the adopter's workflow; wrangle's reusable workflow stops at hash-pinned tarball handoff plus L3 verify.
- **Other constraints.** npm CLI ≥ 11.5.1, Node ≥ 22.14.0, GHA-hosted runners only (and GitLab), provenance unavailable for private-source-repo packages, one trusted publisher per package at a time, cannot publish a package's first version (bootstrap is a manual `npm publish` from a maintainer's terminal — see [npm/cli#8544](https://github.com/npm/cli/issues/8544)).
- **Legacy fallback:** `NPM_TOKEN` (granular or classic automation token) set as `NODE_AUTH_TOKEN`. Required for first-publish bootstrap and for adopters who can't meet the trusted-publishing constraints.

**Sources:** [npm Trusted publishers](https://docs.npmjs.com/trusted-publishers/), [GA changelog](https://github.blog/changelog/2025-07-31-npm-trusted-publishing-with-oidc-is-generally-available/).

### Attestation — wrangle's own L3 (always) + npm's L2 in-CLI (registry slot)

This is the load-bearing decision and where the npm spec aligns to the python and container patterns. Two attestations exist, in two places, serving two surfaces:

**1. Wrangle's L3 SLSA provenance — always emitted, lives in wrangle's metadata directory.**

- Wrangle hashes the `.tgz` produced by `npm pack`, then invokes `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml` with the hash as a base64 subject. The generator runs in an isolated, non-falsifiable builder workflow and emits a Sigstore-signed in-toto bundle.
- Wrangle stores the bundle at `metadata/npm/<shortname>/multiple.intoto.jsonl` — the **same path and shape as python and container** (unified metadata layout, [`docs/SPEC.md`](../../../docs/SPEC.md)).
- Verifiable offline via `slsa-verifier verify-artifact --provenance-path … --source-uri github.com/<owner>/<repo> <tgz>` against the bundle, by any consumer that can fetch wrangle's metadata artifact (or the bundle attached to a GitHub Release).
- Wrangle's metadata directory holds the L3 bundle alongside the SBOM, OSV-Scanner output, build summary, and any other per-build artifacts. Multiple attestations per artifact are not a constraint here.
- The SLSA generator MUST be referenced by tag (`@vX.Y.Z`), not SHA, due to its OIDC verification model — same exception python and container already document (see #147).

**2. Pre-publish verification — wrangle runs `slsa-verifier verify-artifact` against its own bundle between build and publish.**

- Closes the gap that npm's `npm audit signatures` (registry-side, post-publish) leaves open.
- Mirrors the python pattern's `verify-provenance` step. If verification fails, the wrangle reusable workflow fails, and the caller's publish job — gated on `needs:` propagation — is blocked.

**3. npm's L2 in-CLI attestation — populated by the adopter at publish time, lives in the npm registry slot.**

- The adopter's caller workflow runs `npm publish <tgz> --provenance --access public`. This produces an additional Sigstore-signed in-toto Statement carrying a SLSA Provenance predicate, stored in Rekor and attached to the registry's per-version attestation slot. `npm audit signatures` verifies it for downstream consumers.
- This is **L2, not L3** — the build runs on the adopter's GHA runner with the adopter's full workflow context, not in an isolated builder. That's fine: this attestation's job is to satisfy `npm audit signatures` and the registry's UI, not to be the highest-grade provenance available. Wrangle's L3 in (1) covers that.
- Adopters publishing to private registries omit `--provenance` (it doesn't work there). They still have wrangle's L3 from (1) — the design doesn't degrade for the private-registry case.
- Predicate version emitted by the npm CLI is currently SLSA v1.0; the registry retains v0.2 for backward compatibility ([npm/provenance README](https://github.com/npm/provenance)).

**4. The SLSA Node.js builder is NOT the v0.1 path.**

- The [SLSA Node.js builder](https://github.com/slsa-framework/slsa-github-generator/tree/main/internal/builders/nodejs) (`builder_nodejs_slsa3.yml`) is a different mechanism: it runs the npm build inside an isolated builder workflow and uploads the resulting L3 bundle into the npm registry slot via `npm publish --provenance-file=<bundle>` ([npm 9.7.0+](https://github.com/npm/cli/pull/6490)).
- Trade-offs that make it the wrong v0.1 pick: still **beta** as of April 2026 ([Node.js Builder GA milestone](https://github.com/slsa-framework/slsa-github-generator/milestones)); npm-only as builder (pnpm/yarn/lerna unsupported); **workspaces unsupported** ([slsa-github-generator#1789](https://github.com/slsa-framework/slsa-github-generator/issues/1789)); no `pull_request`.
- Adopters who specifically want the L3 bundle to occupy the npm registry slot (rather than living only in wrangle's metadata directory) can use the Node.js builder as an alternative; the wrangle pipeline composes orthogonally with that choice.

**Sources:** [GitHub blog: npm package provenance](https://github.blog/security/supply-chain-security/introducing-npm-package-provenance/), [npm/provenance](https://github.com/npm/provenance), [SLSA Node.js builder docs](https://github.com/slsa-framework/slsa-github-generator/tree/main/internal/builders/nodejs), [npm/cli#6490](https://github.com/npm/cli/pull/6490), [SLSA generic generator README](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md).

### Linting — ecosystem norms; source-stage placement

- **ESLint** is the dominant linter. Canonical invocation is `eslint .` against the project root, configured via `eslint.config.js` (flat config, ESLint 9+) or legacy `.eslintrc.{js,json,yml}`. Most projects also expose it as `npm run lint`.
- **Prettier** is widely paired for formatting. **TypeScript** projects also typically run `tsc --noEmit` for type-checking.
- Reference setups: [`vercel/next.js`](https://github.com/vercel/next.js) uses ESLint + custom rules via `npm run lint`; [`facebook/react`](https://github.com/facebook/react) uses ESLint + Prettier coordinated through Yarn workspace scripts.
- **Source vs. build placement:** linting fits more naturally in wrangle's **source stage** (alongside OSV-Scanner, Zizmor, Scorecard) than in the build stage. The build action could optionally invoke `npm run lint` if a `lint` script is declared in `package.json`, but the primary source-scan placement is the right home.

### Tests — `npm test`

- **Pick:** `npm test` if `package.json` declares a non-default `"test"` script.
- **Why:** `npm test` is the canonical entrypoint regardless of which test runner the project uses (Jest, Vitest, Mocha, Node's built-in `node:test`, etc.). The wrangle build script runs it conditionally — many libraries publish without a `test` script wired into `package.json`, and the npm default `"echo \"Error: no test specified\" && exit 1"` should be detected and skipped rather than failing the build.

## Wrangle's value-add

Wrangle generates and owns its own L3 SLSA provenance regardless of what the npm registry happens to serve. The value-add:

- **Wrangle-owned L3 provenance.** Generated via `generator_generic_slsa3.yml` over the packed `.tgz` and stored in `metadata/npm/<shortname>/multiple.intoto.jsonl`. Same pattern as python and container; cross-ecosystem audit tooling reads the same shape regardless of build type.
- **Pre-publish verification.** Wrangle has its own offline-verifiable bundle. `slsa-verifier verify-artifact` runs between build and publish. If the dist is tampered with between wrangle's build and the adopter's publish, verification fails and publish is blocked — caught as a wrangle-owned guarantee rather than per-adopter boilerplate.
- **Private registry coverage.** GitHub Packages, Verdaccio, Artifactory, and Nexus do not accept the npm `--provenance` flow, but consumers downloading from those registries can still verify wrangle's L3 against the bundle in wrangle's metadata directory or attached to GitHub Releases. Wrangle's L3 does not live in the npm registry slot, so it survives the choice of registry.
- **Multiple attestations per artifact.** Wrangle's metadata directory holds the L3 bundle alongside the SBOM, OSV-Scanner SARIF, build summary, and other per-build artifacts. The npm registry's "one slot per `(package, version)`" rule is a registry concern that wrangle's metadata layout simply does not have.
- **SBOM generation** — `--provenance` does not emit an SBOM. Wrangle produces SPDX (`metadata/npm/<shortname>/sbom.spdx.json`).
- **Vulnerability scanning** of the dependency tree using OSV-Scanner against the lockfile.
- **Test gating** — `--provenance` does not enforce test pass; wrangle does.
- **Hash-pinned dist handoff** — wrangle produces `*.tgz` via `npm pack`, hashes it, and hands the exact bytes to the adopter's publish job. The adopter publishes exactly what wrangle hashed and SBOMed and L3-attested, not whatever a fresh `npm pack` re-emits during publish.
- **Unified metadata layout** — `metadata/npm/<shortname>/` matches the python and container layouts.
- **Release-events gating** — wrangle's existing release-event gate decides whether to publish.

The npm registry's `--provenance` attestation slot is filled by the adopter's caller workflow at publish time. That attestation is a SLSA L2 Sigstore bundle and is what `npm audit signatures` reports. It is independent of wrangle's L3 — they live in different places and serve different surfaces.

**On the python-shaped split.** The python-style split (build + verify in wrangle's reusable workflow; publish in the adopter's workflow) **transfers directly to npm**. The reason is the same: trusted publishing's OIDC `workflow_ref` claim is bound to the caller's workflow filename, so publish must live in the adopter's workflow. The split is not a wrangle preference — it's a constraint of the registry's auth model.

## Awkward cases

- **Workspaces / monorepos.** A single repo with `workspaces: ["packages/*"]` produces N tarballs from one build. v0.1 supports single-package npm only. Workspaces fan-out is a future iteration. The wrangle-owned L3 path scales naturally — N hashes, N subjects to the generic generator, N entries in the bundle — whereas the SLSA Node.js builder explicitly does not support workspaces ([#1789](https://github.com/slsa-framework/slsa-github-generator/issues/1789)).
- **Lifecycle hooks.** `package.json`'s `prepublish`, `prepublishOnly`, `prepack`, `postpack`, and `prepare` scripts run during `npm publish` and `npm pack`. They can rebuild or modify what's in the tarball **between** wrangle's hash step and `npm publish`'s upload. Mitigation: wrangle runs `npm pack` to produce the tarball, hashes it, then the adopter's publish job runs `npm publish <packed.tgz>` — `prepublish` hooks don't re-fire on a tarball-direct publish, and pre-publish `slsa-verifier verify-artifact` would catch any tampering anyway.
- **Scoped packages (`@scope/name`).** Default to private-paid; first publish requires `--access public`. Adopters miss this constantly; the example workflow should call it out.
- **Initial publish bootstrap.** Trusted publishing cannot publish a package's first version ([npm/cli#8544](https://github.com/npm/cli/issues/8544)). Adopters need a one-time manual `npm publish` from a maintainer's terminal before wrangle's automated path works.
- **Pre-release / dist-tags.** `npm publish --tag beta` publishes under a non-`latest` dist-tag. The contract should let adopters pass through the tag without wrangle re-implementing tag logic.
- **Native modules / pre-built binaries.** Packages like `bcrypt`, `sharp`, and `node-sass`-era projects ship compiled C/C++ bindings. The npm/Node.js community handles this via three patterns:
  - **(a) Source-only publish + rebuild on install.** The package ships C/C++ source; `node-gyp` compiles it during `npm install` against the consumer's local toolchain. Most portable; slowest install; assumes a working `node-gyp` setup downstream.
  - **(b) `prebuild-install` / `node-pre-gyp` + GitHub Releases.** Pre-built binaries per `(node-version, platform, arch)` triple are uploaded to GitHub Releases at publish time; the install hook downloads the matching binary, falling back to source build if no match.
  - **(c) `optionalDependencies` + per-platform packages.** The pattern esbuild, swc, rollup, and friends use: a thin "loader" package depends on `@scope/<name>-linux-x64`, `@scope/<name>-darwin-arm64`, etc., as `optionalDependencies`; npm only installs the entry matching the consumer's platform. Each per-platform sub-package is itself published to npm with its compiled binary inside.
  - SBOM coverage of the C/C++ portion is its own problem: `npm sbom` reads `package-lock.json` and won't cover compiled native code; `syft` against the installed `node_modules/<pkg>/build/` or `prebuilds/` directory has partial coverage. Wrangle's v0.1 should document this gap explicitly rather than try to cover compiled native bytes; the L3 provenance still attests to the npm-published `.tgz` regardless of what's inside it.
- **`prepare` script in transitive dev-deps.** Runs during `npm ci`. `npm ci --ignore-scripts` is safer for CI but breaks projects whose own build relies on a dep's prepare. No clean answer; default to running scripts and document the trade-off.
- **ESM vs. CJS, TypeScript transpilation.** Orthogonal to wrangle (handled by the project's `npm run build`), but worth flagging — wrangle treats the build as opaque and packages whatever `package.json`'s `"files"` field says is in-scope.
- **Private registries.** The npm-CLI `--provenance` flow does not work against `npm.pkg.github.com`, Verdaccio, Artifactory, or Nexus. Adopters publishing privately omit `--provenance` from the publish step; they still get wrangle's L3 bundle in `metadata/npm/<shortname>/` and at the GitHub Release, and consumers can verify against that bundle independently of the registry.

## Implementation notes

Practical things the implementer will hit. Not contract-design speculation; that's [#171](https://github.com/TomHennen/wrangle/issues/171).

- **`build.sh` outline:**
  1. Validate inputs via `lib/validate_path.sh`.
  2. `npm ci` (lockfile-faithful install; not `npm install`).
  3. If `package.json`'s `"scripts.build"` exists: `npm run build`.
  4. If `"scripts.test"` exists and isn't the default no-op: `npm test`.
  5. `npm pack` to produce `<name>-<version>.tgz` (scoped: `<scope>-<name>-<version>.tgz`).
  6. SHA-256 the tarball; emit base64 hashes in the format `slsa-github-generator`'s `base64-subjects` input expects (see python step 5 for the exact `cd dist/` + bare-`*` pattern that keeps subjects as bare filenames so `slsa-verifier` matches them).
  7. `npm sbom --sbom-format=spdx` to produce `sbom.spdx.json`.
  8. OSV-Scanner against the lockfile.
  9. Write the unified `metadata/npm/<shortname>/` directory: `sbom.spdx.json`, `vuln-scan.json`, `summary.md`, `outputs.txt`.
- **Reusable workflow shape mirrors python's:**
  1. `build` job runs the composite (steps above), uploads `npm-dist-<shortname>` and `npm-metadata-<shortname>` artifacts.
  2. `gate` job runs `actions/release_gate` and exposes `should-release`.
  3. `provenance` job (gated on `should-release`) calls `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@vX.Y.Z` with the build's `hashes` output. Re-export the generator's `provenance-name` so the bundle can be downloaded by name and stored in `metadata/npm/<shortname>/multiple.intoto.jsonl`.
  4. `verify` job (gated on `should-release && verify-provenance`) downloads dist + provenance, installs `slsa-verifier`, and runs `slsa-verifier verify-artifact --provenance-path metadata/npm/<shortname>/multiple.intoto.jsonl --source-uri github.com/<owner>/<repo> <tgz>`. Verify failure fails the workflow; the adopter's publish (gated on `needs:`) is blocked.
- **Reflection on `package.json`.** Steps 3 and 4 are conditional on `"scripts.build"` and `"scripts.test"` being defined. Use `jq` against `package.json` rather than running `npm run build` and catching the "missing script" exit code — clearer logs.
- **`actions/setup-node`** is the standard glue for getting Node and the `.npmrc` `registry-url` wired correctly. It belongs in the example workflow's setup, not in wrangle's `build.sh`.
- **GitHub now blocks** ([Sep 2023 changelog](https://github.blog/changelog/2023-09-27-block-npm-package-publishes-when-names-and-versions-dont-match-between-manifest-and-tarball-package-json/)) publishes where the manifest's `name`/`version` mismatches the tarball's internal `package.json` — the `npm pack` → hash → `npm publish` sequence binds cleanly.
- **Tarball name normalization** for scoped packages: `@scope/name` becomes `scope-name-version.tgz`. The build script needs to compute the expected filename, not glob.
- **Publish job in the example workflow** runs `npm publish ${{ inputs.tarball-path }} --provenance --access public` with `permissions: { id-token: write, contents: read }`. The `--provenance` flag is implicit under trusted publishing (auto-on) but harmless to pass explicitly. Adopters publishing to private registries drop the `--provenance` flag — they still have wrangle's L3 in metadata.
- **Permissions parallel python's:** `build` job needs only `contents: read`; `provenance` job needs `actions: read`, `id-token: write`, `contents: write` (the last for the SLSA generator's `upload-assets` job; callers must grant the same).

## Open questions

- **Future: lobby `npm publish --provenance-file` to accept generic-generator-built bundles.** Tom raised this in PR #178 review (L107) as a possible future direction. Today `--provenance-file` is documented only with the SLSA Node.js builder as the producer; whether the npm registry validates the contents structurally vs. accepting any GHA-issued Sigstore bundle whose subject matches the tarball's hash was not resolved in the research window. If the registry can be extended (or already accepts) generic-generator bundles, wrangle could populate the npm registry slot with its L3 in addition to (or instead of) the in-CLI L2. This is a future-iteration item, not a v0.1 blocker — wrangle's L3 already lives in metadata regardless.
- **`npm sbom` SPDX conformance.** The CycloneDX critique is well-known for `npm sbom`'s CycloneDX output; whether the SPDX output has equivalent conformance issues was not directly verified. If material, `syft` is the obvious fallback (already in wrangle's tool inventory, used by the python build type).
- **Predicate version emitted in practice.** The npm CLI's [provenance README](https://github.com/npm/provenance) states v1.0 predicates today; some older docs reference v0.2. Whether verifiers in the wild accept both, and which the registry surfaces in `npm audit signatures`, was not fully resolved. Orthogonal to wrangle's L3 (which is whatever the generic generator emits), but relevant to the L2-in-the-registry side.
- **Native-module SBOM coverage.** Flagged in awkward cases above; no clean answer for the C/C++ portion. The L3 attestation covers the npm `.tgz` regardless of what's inside it, but SBOM completeness for native components is a real gap.
