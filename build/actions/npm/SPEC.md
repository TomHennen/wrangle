# Wrangle npm Build Type — Phase 1 Research

**Status:** Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md). Recommends defaults for an eventual `build/actions/npm/` implementation. No `action.yml`, reusable workflow, example workflow, or test fixture exists yet.

## Overview

The npm ecosystem in 2026 is large, mature, and structurally well-suited to a wrangle build type: artifacts are file-based (`*.tgz`), the registry is centralized on npmjs.org, OIDC trusted publishing is GA, and `npm publish --provenance` already produces a Sigstore-signed SLSA attestation by default. Most npm projects publish a single package from a single repo — workspace/monorepo cases exist but are a minority and have well-known coordination tools (changesets, Lerna, Nx).

**Operating model.** Wrangle owns the build hygiene — install, test, SBOM, vulnerability scan, hash-pinned tarball handoff, and the unified `metadata/<type>/<shortname>/` layout. The upstream attestation tooling (`npm publish --provenance` today, and the SLSA Node.js builder later) owns the SLSA envelope. One attestation per published version. Wrangle's hygiene composes orthogonally to whichever envelope the adopter picks.

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

- **Pick:** **npmjs.org** as the only supported registry for v0.1.
- **Why:** provenance attachment is wired into npmjs.org specifically. The Sigstore-bundle-to-registry handoff does not exist for self-hosted registries (Verdaccio, Artifactory, Nexus) and the npm provenance docs explicitly call out only `registry.npmjs.org` and GitLab.
- **GitHub Packages excluded.** `npm.pkg.github.com` is not in the npm provenance docs' supported list and the Sigstore handoff is not wired there. Adopters publishing to GitHub Packages get the build pipeline (test, SBOM, vuln scan, hash-pinned handoff) but no attestation surface — same shape as python's "no Trusted Publishing for private PyPI" gap.

**Sources:** [npm Generating provenance statements](https://docs.npmjs.com/generating-provenance-statements/).

### Authentication — Trusted Publishing (OIDC)

- **Pick:** **npm Trusted Publishing** (GA [2025-07-31](https://github.blog/changelog/2025-07-31-npm-trusted-publishing-with-oidc-is-generally-available/)).
- **Mechanics.** Adopter configures a trusted publisher on npmjs.com → Packages → `<package>` → Settings → Trusted publishing, pinning a GitHub repo + workflow filename + optional environment. The publish workflow grants `id-token: write`, runs `actions/setup-node` with `registry-url: 'https://registry.npmjs.org'`, then runs `npm publish` with no `NODE_AUTH_TOKEN`. The npm CLI exchanges the GHA OIDC token for a short-lived publish credential. Provenance is auto-on under trusted publishing.
- **Constraints (per the npm Trusted Publishers docs Troubleshooting paragraph):** the OIDC token's `workflow_ref` claim is bound to the **caller** workflow's filename. A reusable workflow that calls `npm publish` for adopters does not satisfy this constraint — the `workflow_ref` is the caller's, not the reusable workflow's path. **This is the same caller-bound publish constraint as PyPI.** Implication: publish lives in the adopter's workflow; wrangle's reusable workflow stops at hash-pinned tarball handoff.
- **Other constraints.** npm CLI ≥ 11.5.1, Node ≥ 22.14.0, GHA-hosted runners only (and GitLab), provenance unavailable for private-source-repo packages, one trusted publisher per package at a time, cannot publish a package's first version (bootstrap is a manual `npm publish` from a maintainer's terminal — see [npm/cli#8544](https://github.com/npm/cli/issues/8544)).
- **Legacy fallback:** `NPM_TOKEN` (granular or classic automation token) set as `NODE_AUTH_TOKEN`. Required for first-publish bootstrap and for adopters who can't meet the trusted-publishing constraints.

**Sources:** [npm Trusted publishers](https://docs.npmjs.com/trusted-publishers/), [GA changelog](https://github.blog/changelog/2025-07-31-npm-trusted-publishing-with-oidc-is-generally-available/).

### Attestation — `npm publish --provenance` direct (L2) for v0.1

- **Pick for v0.1:** plain `npm publish --provenance`.
- **Why this is the right v0.1 pick.**
  - **GA and stable** since April 2023, used in production by a long tail of packages.
  - **Works for all three managers** — `npm`/`pnpm`/`yarn` can all invoke it (yarn berry via `yarn npm publish --provenance` since v4.9).
  - **Supports workspaces** (per-workspace provenance via N publish invocations, coordinated by changesets/Lerna/Nx if needed).
  - **Supports all event triggers** including `pull_request`.
  - **SLSA Build L2** — Sigstore-keyless signed in-toto Statement carrying a SLSA Provenance predicate, stored in Rekor and on the registry, verified by `npm audit signatures` against the Sigstore bundle. Provenance predicate version emitted by the npm CLI is currently SLSA v1.0; the registry retains v0.2 for backward compatibility ([npm/provenance README](https://github.com/npm/provenance)). The build is not isolated in a non-falsifiable builder (it runs on the adopter's GHA runner with the adopter's full workflow context), so the level is L2, not L3.
- **L3 upgrade path (documented, not the v0.1 pick).**
  - The [SLSA Node.js builder](https://github.com/slsa-framework/slsa-github-generator/tree/main/internal/builders/nodejs) (`builder_nodejs_slsa3.yml`) runs the npm build inside an isolated builder workflow and produces SLSA Build L3 provenance. Internally it uploads the L3 bundle via `npm publish --provenance-file=<bundle>` ([npm 9.7.0+](https://github.com/npm/cli/pull/6490)).
  - `--provenance` and `--provenance-file` are **mutually exclusive at publish time** — the npm registry has **one attestation slot per published version**. The Node.js builder replaces the in-CLI `--provenance` flow rather than augmenting it.
  - **Node.js builder caveats:** still **beta** as of April 2026 ([Node.js Builder GA milestone](https://github.com/slsa-framework/slsa-github-generator/milestones)); npm-only as builder (pnpm/yarn/lerna unsupported); **workspaces unsupported** ([slsa-github-generator#1789](https://github.com/slsa-framework/slsa-github-generator/issues/1789)); no `pull_request`.
  - The L3 upgrade is a future-iteration option; v0.1 picks `--provenance` because it's GA, covers the broader compatibility matrix, and meaningfully improves on no-attestation today.

**Sources:** [GitHub blog: npm package provenance](https://github.blog/security/supply-chain-security/introducing-npm-package-provenance/), [npm/provenance](https://github.com/npm/provenance), [SLSA Node.js builder docs](https://github.com/slsa-framework/slsa-github-generator/tree/main/internal/builders/nodejs), [npm/cli#6490](https://github.com/npm/cli/pull/6490).

### Linting — ecosystem norms; source-stage placement

- **ESLint** is the dominant linter. Canonical invocation is `eslint .` against the project root, configured via `eslint.config.js` (flat config, ESLint 9+) or legacy `.eslintrc.{js,json,yml}`. Most projects also expose it as `npm run lint`.
- **Prettier** is widely paired for formatting. **TypeScript** projects also typically run `tsc --noEmit` for type-checking.
- Reference setups: [`vercel/next.js`](https://github.com/vercel/next.js) uses ESLint + custom rules via `npm run lint`; [`facebook/react`](https://github.com/facebook/react) uses ESLint + Prettier coordinated through Yarn workspace scripts.
- **Source vs. build placement:** linting fits more naturally in wrangle's **source stage** (alongside OSV-Scanner, Zizmor, Scorecard) than in the build stage. The build action could optionally invoke `npm run lint` if a `lint` script is declared in `package.json`, but the primary source-scan placement is the right home.

### Tests — `npm test`

- **Pick:** `npm test` if `package.json` declares a non-default `"test"` script.
- **Why:** `npm test` is the canonical entrypoint regardless of which test runner the project uses (Jest, Vitest, Mocha, Node's built-in `node:test`, etc.). The wrangle build script runs it conditionally — many libraries publish without a `test` script wired into `package.json`, and the npm default `"echo \"Error: no test specified\" && exit 1"` should be detected and skipped rather than failing the build.

## Wrangle's value-add

Even though `npm publish --provenance` is itself a SLSA L2 attestation, wrangle's hygiene layer is concretely additive:

- **SBOM generation** — `--provenance` does not emit an SBOM. Wrangle produces SPDX (`metadata/npm/<shortname>/sbom.spdx.json`) consistent with python and container.
- **Vulnerability scanning** of the dependency tree using OSV-Scanner against the lockfile.
- **Test gating** — `--provenance` does not enforce test pass; wrangle does.
- **Hash-pinned dist handoff** — wrangle produces `*.tgz` via `npm pack`, hashes it, and hands the exact bytes to the adopter's publish job. The adopter publishes exactly what wrangle hashed and SBOMed, not whatever a fresh `npm pack` re-emits during publish.
- **Unified metadata layout** — `metadata/npm/<shortname>/` matches the python and container layouts so cross-ecosystem audit tooling works uniformly.
- **Release-events gating** — wrangle's existing release-event gate decides whether to publish.

**On L2-vs-L3 orthogonality.** Wrangle's value-add is the same regardless of which envelope the adopter eventually uses. The `--provenance` (L2) path benefits from wrangle's SBOM/test/scan/hash-pinned handoff; the Node.js builder (L3) path also benefits from the same hygiene because the L3 envelope covers build provenance, not SBOM/vuln-scan/test-gating. Wrangle owns hygiene; upstream owns the SLSA envelope.

**On the python-shaped split.** The python-style split (build + verify in wrangle's reusable workflow; publish in the adopter's workflow) **transfers directly to npm**. The reason is the same: trusted publishing's OIDC `workflow_ref` claim is bound to the caller's workflow filename, so publish must live in the adopter's workflow ([npm Trusted publishers Troubleshooting](https://docs.npmjs.com/trusted-publishers/), structurally equivalent to the PyPI constraint in [pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096)). The split is not a wrangle preference — it's a constraint of the registry's auth model.

## Awkward cases

- **Workspaces / monorepos.** A single repo with `workspaces: ["packages/*"]` produces N tarballs from one build. v0.1 supports single-package npm only. Workspaces fan-out is a future iteration. Note that the SLSA Node.js builder explicitly does not support workspaces ([#1789](https://github.com/slsa-framework/slsa-github-generator/issues/1789)) — plain `--provenance` does (per-workspace).
- **Lifecycle hooks.** `package.json`'s `prepublish`, `prepublishOnly`, `prepack`, `postpack`, and `prepare` scripts run during `npm publish` and `npm pack`. They can rebuild or modify what's in the tarball **between** wrangle's hash step and `npm publish`'s upload. Mitigation: wrangle runs `npm pack` to produce the tarball, hashes it, then the adopter's publish job runs `npm publish <packed.tgz>` — `prepublish` hooks don't re-fire on a tarball-direct publish.
- **Scoped packages (`@scope/name`).** Default to private-paid; first publish requires `--access public`. Adopters miss this constantly; the example workflow should call it out.
- **Initial publish bootstrap.** Trusted publishing cannot publish a package's first version ([npm/cli#8544](https://github.com/npm/cli/issues/8544)). Adopters need a one-time manual `npm publish` from a maintainer's terminal before wrangle's automated path works.
- **Pre-release / dist-tags.** `npm publish --tag beta` publishes under a non-`latest` dist-tag. The contract should let adopters pass through the tag without wrangle re-implementing tag logic.
- **Native modules / pre-built binaries.** Packages like `bcrypt` and `node-sass`-era projects compile native code; SBOM coverage for the C/C++ portion is its own problem and wrangle does not cover it.
- **`prepare` script in transitive dev-deps.** Runs during `npm ci`. `npm ci --ignore-scripts` is safer for CI but breaks projects whose own build relies on a dep's prepare. No clean answer; default to running scripts and document the trade-off.
- **ESM vs. CJS, TypeScript transpilation.** Orthogonal to wrangle (handled by the project's `npm run build`), but worth flagging — wrangle treats the build as opaque and packages whatever `package.json`'s `"files"` field says is in-scope.
- **Private registries.** Provenance does not work against `npm.pkg.github.com`, Verdaccio, Artifactory, or Nexus. Adopters publishing privately get the build pipeline but not the attestation surface.

## Implementation notes

Practical things the implementer will hit. Not contract-design speculation.

- **`build.sh` outline:**
  1. Validate inputs via `lib/validate_path.sh`.
  2. `npm ci` (lockfile-faithful install; not `npm install`).
  3. If `package.json`'s `"scripts.build"` exists: `npm run build`.
  4. If `"scripts.test"` exists and isn't the default no-op: `npm test`.
  5. `npm pack` to produce `<name>-<version>.tgz` (scoped: `<scope>-<name>-<version>.tgz`).
  6. SHA-256 the tarball; write to metadata.
  7. `npm sbom --sbom-format=spdx` to produce `sbom.spdx.json`.
  8. OSV-Scanner against the lockfile.
  9. Write the unified `metadata/npm/<shortname>/` directory: `sbom.spdx.json`, `vuln-scan.json`, `summary.md`, `outputs.txt` (hashes for SLSA generator subjects).
- **Reflection on `package.json`.** Steps 3 and 4 are conditional on `"scripts.build"` and `"scripts.test"` being defined. Use `jq` against `package.json` rather than running `npm run build` and catching the "missing script" exit code — clearer logs.
- **`actions/setup-node`** is the standard glue for getting Node and the `.npmrc` `registry-url` wired correctly. It belongs in the example workflow's setup, not in wrangle's `build.sh`.
- **GitHub now blocks** ([Sep 2023 changelog](https://github.blog/changelog/2023-09-27-block-npm-package-publishes-when-names-and-versions-dont-match-between-manifest-and-tarball-package-json/)) publishes where the manifest's `name`/`version` mismatches the tarball's internal `package.json` — the `npm pack` → hash → `npm publish` sequence binds cleanly.
- **Tarball name normalization** for scoped packages: `@scope/name` becomes `scope-name-version.tgz`. The build script needs to compute the expected filename, not glob.
- **Publish job in the example workflow** runs `npm publish ${{ inputs.tarball-path }} --provenance --access public` with `permissions: { id-token: write, contents: read }`. The `--provenance` flag is implicit under trusted publishing (auto-on) but harmless to pass explicitly.
- **Eventual contract-design pass ([#171](https://github.com/TomHennen/wrangle/issues/171))** will pick between contract shapes (artifact-identity boundary vs. pre-push boundary, etc.). v0.1 follows the python-shaped split: wrangle owns build + hygiene + hashed handoff, adopter owns publish.

## Open questions

Items requiring adoption-grade verification or evidence that couldn't be obtained in the research window.

- **"One attestation slot per published version" semantics.** The L2→L3 substitution claim depends on the npm registry holding one provenance attestation per `(package, version)` tuple. Behaviorally consistent with what the SLSA Node.js builder does (uses `--provenance-file` instead of `--provenance`, never alongside) and with the npm CLI rejecting both flags together, but adoption-grade verification (e.g., trying to attach two attestations and observing the registry's response, or finding an explicit registry-side spec statement) is **research-grade as of this writing.** Worth confirming before recommending adopters move from L2 to L3 in production.
- **`npm sbom` SPDX conformance.** The CycloneDX critique is well-known for `npm sbom`'s CycloneDX output; whether the SPDX output has equivalent conformance issues was not directly verified. If material, `syft` is the obvious fallback.
- **Predicate version emitted in practice.** The npm CLI's [provenance README](https://github.com/npm/provenance) states v1.0 predicates today; some older docs reference v0.2. Whether verifiers in the wild accept both, and which the registry surfaces in `npm audit signatures`, was not fully resolved.
- **Pre-publish verification analog.** Wrangle's python pattern includes `slsa-verifier verify-artifact` between build and publish. For npm the equivalent (`npm audit signatures`) requires the registry-side state, which only exists post-publish — same asymmetry as container's "digest only after push." Whether there's a community-recognized pre-publish verify shape (e.g., `npm publish --dry-run` plus tarball hash comparison) wasn't resolvable from the materials reviewed. Same shape as the container case.
