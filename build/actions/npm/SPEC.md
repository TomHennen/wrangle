# Wrangle npm Build Type — Phase 1 Research

**Status:** Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md). Recommends defaults for an eventual `build/actions/npm/` implementation. No `action.yml`, reusable workflow, example workflow, or test fixture exists yet.

## Overview

The npm ecosystem in 2026 is large, mature, and structurally well-suited to a wrangle build type: artifacts are file-based (`*.tgz`), the registry is centralized on npmjs.org, OIDC trusted publishing is GA, and `npm publish --provenance` already produces a Sigstore-signed SLSA L2 attestation by default. Most npm projects publish a single package from a single repo — workspace/monorepo cases exist but are a minority and have well-known coordination tools (changesets, Lerna, Nx).

**Operating model.** Wrangle owns the build hygiene **and its own L3 SLSA provenance**, just like the python and container build types. Concretely:

1. Wrangle invokes the build (`npm ci` → optional `npm run build` → optional `npm test` → `npm pack`).
2. Wrangle runs `actions/attest-build-provenance` (`subject-path: dist/*`) in an `attest:` job inside its reusable workflow. The action emits an L3 Sigstore-signed in-toto bundle, uploaded as a separate workflow artifact; the per-artifact VSA is attached as a GitHub Release asset on tag pushes.
3. Wrangle's metadata artifact (`npm-metadata-<shortname>`) holds the SBOM, OSV-Scanner output, and build summary per the unified metadata layout. The L3 bundle artifact is exposed via the reusable workflow's `provenance-artifact-name` output so adopters can find it without reconstructing the filename.
4. Wrangle's `vsa` job verifies the provenance (ampel against the wrangle PolicySet, fail-closed) and emits the signed VSA before publish — closing the pre-publish verification gap.
5. The adopter's caller workflow publishes the hash-pinned `.tgz` with `npm publish --provenance`. That populates the npm registry's attestation slot with an additional **L2 in-CLI attestation** that `npm audit signatures` can verify.

The two attestations live in two different places and serve two different surfaces. Wrangle does not have to fight the npm registry's "one attestation slot per `(package, version)`" constraint, because wrangle's L3 is a separate workflow artifact, not in the registry slot.

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

### SBOM — `syft`

- **Pick:** [`syft`](https://github.com/anchore/syft), the same tool wrangle's python build type uses, with the same Cosign-keyless-verified install (`tools/syft/install.sh`).
- **Why:** Reuses an existing wrangle-verified install, produces SPDX natively (matching wrangle's cross-build-type SPDX standardization), and is OWASP-known-conformant. An earlier draft of this SPEC picked `npm sbom --sbom-format=spdx` (in-tree, npm 10+) but its conformance has been publicly criticized by the OWASP CycloneDX project lead (registry-integrity-hashes placed on components, license-parsing dropouts), and the equivalent claim for SPDX output was contested rather than settled. Switching to `syft` removes the question entirely. The contract — "wrangle produces a good SPDX SBOM at `metadata/npm/<shortname>/sbom.spdx.json`" — does not change.
- **Manager-agnostic.** `syft` reads the project source tree, so it works for npm, pnpm, and Yarn variants without per-manager branching when those land in v0.2+.
- **Native code is not covered by source-tree scanning.** Bundled C/C++ binaries that `prebuild-install` fetches at consumer install time are not in source — see "Awkward cases — Native modules" for the layered-scanner recommendation.

**Sources:** [syft](https://github.com/anchore/syft), [unified metadata layout](../../../docs/SPEC.md).

### Publish target — npmjs.org via Trusted Publishing

- **Pick:** **npmjs.org** as the only fully-supported publish-with-`--provenance` registry for v0.1. Adopters publishing to private registries (GitHub Packages, Verdaccio, Artifactory, Nexus) still get the wrangle pipeline including wrangle's own L3 bundle in `metadata/npm/<shortname>/`; they just don't get the registry-side L2 slot filled. See the attestation section below for why this matters less than it would have under the prior framing.
- **Why npmjs.org for `--provenance` specifically:** the in-CLI `--provenance` flow is wired to `registry.npmjs.org` (and GitLab); the Sigstore-bundle-to-registry handoff does not exist for self-hosted registries.

**Sources:** [npm Generating provenance statements](https://docs.npmjs.com/generating-provenance-statements/).

### Authentication — Trusted Publishing (OIDC)

- **Pick:** **npm Trusted Publishing** (GA [2025-07-31](https://github.blog/changelog/2025-07-31-npm-trusted-publishing-with-oidc-is-generally-available/)).
- **Mechanics.** Adopter configures a trusted publisher on npmjs.com → Packages → `<package>` → Settings → Trusted publishing, pinning a GitHub repo + workflow filename + optional environment. The publish workflow grants `id-token: write`, runs `actions/setup-node` with `registry-url: 'https://registry.npmjs.org'`, then runs `npm publish` with no `NODE_AUTH_TOKEN`. The npm CLI exchanges the GHA OIDC token for a short-lived publish credential. Provenance is auto-on under trusted publishing.
- **`NODE_AUTH_TOKEN` MUST NOT be set on the publish job.** A leftover token (e.g., from an org-level secret reference inherited by the workflow's `env:`) silently bypasses the OIDC binding and downgrades to legacy token auth — `--provenance` would still emit a bundle, but the registry's `workflow_ref` validation would not occur. The example workflow in `gh_workflow_examples/build_npm.yml` deliberately omits `NODE_AUTH_TOKEN`; adopters should not add it back.
- **Caller-bound publish constraint.** The OIDC token's `workflow_ref` claim is bound to the **caller** workflow's filename (per the [npm Trusted Publishers Troubleshooting docs](https://docs.npmjs.com/trusted-publishers/)). A reusable workflow that calls `npm publish` for adopters does not satisfy this constraint — the `workflow_ref` is the caller's, not the reusable workflow's path. **This is the same caller-bound publish constraint as PyPI.** Implication: publish lives in the adopter's workflow; wrangle's reusable workflow stops at hash-pinned tarball handoff plus L3 verify.
- **Other constraints.** npm CLI ≥ 11.5.1, Node ≥ 22.14.0, GHA-hosted runners only (and GitLab), provenance unavailable for private-source-repo packages, one trusted publisher per package at a time, cannot publish a package's first version (bootstrap is a manual `npm publish` from a maintainer's terminal — see [npm/cli#8544](https://github.com/npm/cli/issues/8544)).
- **Legacy fallback:** `NPM_TOKEN` (granular or classic automation token) set as `NODE_AUTH_TOKEN`. Required for first-publish bootstrap and for adopters who can't meet the trusted-publishing constraints.

**Sources:** [npm Trusted publishers](https://docs.npmjs.com/trusted-publishers/), [GA changelog](https://github.blog/changelog/2025-07-31-npm-trusted-publishing-with-oidc-is-generally-available/).

### Attestation — wrangle's own L3 (always) + npm's L2 in-CLI (registry slot)

This is the load-bearing decision and where the npm spec aligns to the python and container patterns. Two attestations exist, in two places, serving two surfaces:

**1. Wrangle's L3 SLSA provenance — always emitted, exposed as a separate workflow artifact.**

- Wrangle runs `actions/attest-build-provenance` (`subject-path: dist/*`) over the `.tgz` produced by `npm pack`, in an `attest:` job *inside* its reusable workflow — the isolated trusted builder. The action emits a Sigstore-signed in-toto bundle carrying a `predicateType: https://slsa.dev/provenance/v1` predicate, naming `build_and_publish_npm.yml` as the `builder.id`.
- The bundle is uploaded as a separate workflow artifact named per the reusable workflow's `provenance-artifact-name` output (`npm-provenance-bundle-<shortname>`, namespaced by shortname so multiple npm builds in one workflow don't collide). The provenance is *also* written to GitHub's attestation store (against the caller's repo) for any `should-release` build, so it stays externally verifiable via `gh attestation verify` regardless of trigger. On tag pushes the per-artifact VSA is additionally attached as a GitHub Release asset by the `vsa:` job; non-tag publishes have no release-attached VSA.
- Wrangle's `npm-metadata-<shortname>` artifact (the unified metadata layout — see [`docs/SPEC.md`](../../../docs/SPEC.md)) holds the SBOM, OSV-Scanner output, build summary, and any other per-build artifacts. The L3 bundle is *parallel* to it, not inside it.
- Verifiable via `gh attestation verify <tgz> --repo <owner>/<repo> --signer-workflow TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml`, which reads the attestation from GitHub's store (scoped by `--repo`).
- `actions/attest-build-provenance` is a plain action, SHA-pinnable like any other — there is no tag-pin exception (the former generic generator required tag invocation for its OIDC model; that no longer applies).

**2. Pre-publish verification — wrangle's `vsa` job verifies the provenance between build and publish.**

- Closes the gap that npm's `npm audit signatures` (registry-side, post-publish) leaves open.
- The `vsa` job (gated on `should-release`) runs ampel via `actions/verify`, which checks the provenance's Sigstore signature against the wrangle PolicySet's `common.identities` (fail-closed: only wrangle's reusable-workflow signer passes) and the SLSA tenets, then emits the signed VSA. If verification fails, the wrangle reusable workflow fails, and the caller's publish job — gated on `needs:` propagation — is blocked.
- **End-to-end coverage.** Wrangle's verify closes the wrangle→caller-publish handoff: it confirms the dist artifact carries L3 provenance that passes the wrangle PolicySet. The caller→registry segment is bound by Trusted Publishing's OIDC `workflow_ref` claim — npm's registry validates that the OIDC token's claimed workflow filename matches the registered trusted publisher. Consumers verifying L2 attestations get end-to-end coverage by checking that `workflow_ref` matches the expected caller workflow path. Wrangle's verify and TP's `workflow_ref` together cover the full source→consumer pipeline.

**3. npm's L2 in-CLI attestation — populated by the adopter at publish time, lives in the npm registry slot.**

- The adopter's caller workflow runs `npm publish <tgz> --provenance --access public`. This produces an additional Sigstore-signed in-toto Statement carrying a SLSA Provenance predicate, stored in Rekor and attached to the registry's per-version attestation slot. `npm audit signatures` verifies it for downstream consumers.
- This is **L2, not L3** — the build runs on the adopter's GHA runner with the adopter's full workflow context, not in an isolated builder. That's fine: this attestation's job is to satisfy `npm audit signatures` and the registry's UI, not to be the highest-grade provenance available. Wrangle's L3 in (1) covers that. Both bundles share the **same Sigstore Public Good Instance** (Fulcio at `fulcio.sigstore.dev`, Rekor at `rekor.sigstore.dev`, TUF at `tuf-repo-cdn.sigstore.dev`); the L2-vs-L3 difference is builder isolation, not the cryptographic root of trust.
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
- **Source-stage placement (wrangle-wide convention):** lint runs in wrangle's source-scan stage (alongside OSV-Scanner, Zizmor, Scorecard), **not** in the build action. The build action does NOT invoke `npm run lint` — that would duplicate the source-scan invocation and conflict with PRs that intentionally block on lint at the source level.

### Tests — `npm test`

- **Pick:** `npm test` if `package.json` declares a non-default `"test"` script.
- **Why:** `npm test` is the canonical entrypoint regardless of which test runner the project uses (Jest, Vitest, Mocha, Node's built-in `node:test`, etc.). The wrangle build script runs it conditionally — many libraries publish without a `test` script wired into `package.json`, and the npm default `"echo \"Error: no test specified\" && exit 1"` should be detected and skipped rather than failing the build.

## Wrangle's value-add

Wrangle generates and owns its own L3 SLSA provenance regardless of what the npm registry happens to serve. The value-add:

- **Wrangle-owned L3 provenance.** Generated via `actions/attest-build-provenance` (run inside wrangle's reusable workflow) over the packed `.tgz`, exposed as a separate workflow artifact; the per-artifact VSA is attached as a GitHub Release asset on tag pushes. Same pattern as python and container; cross-ecosystem audit tooling reads the same shape regardless of build type.
- **Pre-publish verification.** Wrangle has its own offline-verifiable bundle. The `vsa` job verifies the provenance (ampel against the wrangle PolicySet, fail-closed) between build and publish. If the dist is tampered with between wrangle's build and the adopter's publish, verification fails and publish is blocked — caught as a wrangle-owned guarantee rather than per-adopter boilerplate.
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

- **Workspaces / monorepos.** A single repo with `workspaces: ["packages/*"]` produces N tarballs from one build. **v0.1 explicitly rejects workspaces.** `validate_inputs.sh` checks `package.json` for a `workspaces` field via `jq -r 'has("workspaces")'` and exits with a clear error if found. The action also asserts exactly one `.tgz` in `dist/` after `npm pack`, so any workspace setup that slips past validation still fails fast with "expected exactly 1 tarball, found N". Workspaces fan-out is a future iteration. The wrangle-owned L3 path scales naturally — `actions/attest-build-provenance`'s `subject-path dist/*` covers N tarballs as N subjects in one bundle — whereas the SLSA Node.js builder explicitly does not support workspaces ([#1789](https://github.com/slsa-framework/slsa-github-generator/issues/1789)).
- **Lifecycle hooks.** `package.json`'s `prepare`, `prepack`, `postpack`, `prepublish`, and `prepublishOnly` scripts have different firing semantics, and the threat model differs by hook. By default wrangle runs scripts (the ecosystem norm; common tools like husky and prebuild-install rely on them); adopters who want stricter hardening pass `ignore-scripts: true` to the reusable workflow.
  - **`prepare`** fires during `npm ci` (so it runs in wrangle's pipeline) AND for git-installed deps. A compromised dev-dep's `prepare` script can mutate the build tree before `npm pack` runs — wrangle would then hash and attest the post-mutation bytes. **This is by design when scripts are enabled:** the L3 attestation binds to "what wrangle built from this commit's source + lockfile," and the lockfile pins the dev-deps that supply the `prepare` scripts. A malicious script in a pinned dev-dep is the same threat surface as malicious source code in `src/` — both are in version control, both are governed by code review and dep-review. Wrangle's vuln-scan + SBOM is what's supposed to catch known-bad transitive deps; an unknown-bad dep is the same gap as unknown-bad source.
  - **`prepack`** fires during `npm pack`, in wrangle's build job. Same framing as `prepare`: source-controlled, code-reviewable, attested as-is.
  - **`postpack`** fires after `npm pack`, before wrangle's hash step. Same framing.
  - **`prepublishOnly`** fires when `npm publish` is invoked **against a directory**, not a pre-built tarball. Wrangle's pipeline runs `npm publish <packed.tgz>` (tarball-direct publish), so `prepublishOnly` does NOT fire — adopters who relied on it for type-checking should move the work to a regular `build` script.
  - **`prepublish`** is deprecated (npm v7+); behaves like `prepack` when triggered. Same framing.
  - **Opt-in hardening:** `ignore-scripts: true` is the all-or-nothing mode — **nothing in `package.json`'s `scripts` field runs.** Concretely: `--ignore-scripts` is passed to both `npm ci` and `npm pack` (suppressing every hook above), AND `npm run build` and `npm test` are skipped outright. The L3 attestation then binds to "what `npm pack` would produce against this source with no script execution at all." Trade-off: husky's `prepare`-installed git hooks won't be set up (irrelevant for CI), `prebuild-install` binaries won't auto-fetch (consumer-side concern, not wrangle's), any project relying on `prepack` for transpilation will produce an empty/wrong tarball, and any project whose adopters expect a `build`/`test` script to run will need to either (a) un-set this flag, (b) move build/test out of `package.json`, or (c) accept that the published tarball reflects pre-build source. Off-by-default because the breakage is significant for typical projects. If a finer-grained mode is needed later (e.g., suppress transitive hooks but still run the user's declared `build` and `test`), add a separate input rather than overloading this one — the obvious binary is the right v0.1 shape.
- **Scoped packages (`@scope/name`).** Default to private-paid; first publish requires `--access public`. Adopters miss this constantly; the example workflow should call it out.
- **Initial publish bootstrap.** Trusted publishing cannot publish a package's first version ([npm/cli#8544](https://github.com/npm/cli/issues/8544)). Adopters need a one-time manual `npm publish` from a maintainer's terminal before wrangle's automated path works.
- **Pre-release / dist-tags.** `npm publish --tag beta` publishes under a non-`latest` dist-tag. The contract should let adopters pass through the tag without wrangle re-implementing tag logic.
- **Native modules / pre-built binaries.** Packages like `bcrypt`, `sharp`, and `node-sass`-era projects ship compiled C/C++ bindings. The npm/Node.js community handles this via three patterns:
  - **(a) Source-only publish + rebuild on install.** The package ships C/C++ source; `node-gyp` compiles it during `npm install` against the consumer's local toolchain. Most portable; slowest install; assumes a working `node-gyp` setup downstream.
  - **(b) `prebuild-install` / `node-pre-gyp` + GitHub Releases.** Pre-built binaries per `(node-version, platform, arch)` triple are uploaded to GitHub Releases at publish time; the install hook downloads the matching binary, falling back to source build if no match.
  - **(c) `optionalDependencies` + per-platform packages.** The pattern esbuild, swc, rollup, and friends use: a thin "loader" package depends on `@scope/<name>-linux-x64`, `@scope/<name>-darwin-arm64`, etc., as `optionalDependencies`; npm only installs the entry matching the consumer's platform. Each per-platform sub-package is itself published to npm with its compiled binary inside.
  - **SBOM coverage gap.** Wrangle's `syft` runs over the project source tree. Compiled C/C++ binaries that pattern (b)'s `prebuild-install` fetches at consumer install time, or that pattern (c) bundles inside per-platform sub-packages, are not in source — they don't appear in wrangle's SBOM. Adopters consuming wrangle-attested packages with bundled native code SHOULD layer binary scanners (Trivy, Grype) against their own installed `node_modules/` for full CVE coverage. Wrangle does not provide this in v0.1; the L3 provenance still attests to the npm-published `.tgz` regardless of what's inside it.
- **ESM vs. CJS, TypeScript transpilation.** Orthogonal to wrangle (handled by the project's `npm run build`), but worth flagging — wrangle treats the build as opaque and packages whatever `package.json`'s `"files"` field says is in-scope.
- **Private registries.** The npm-CLI `--provenance` flow does not work against `npm.pkg.github.com`, Verdaccio, Artifactory, or Nexus. Adopters publishing privately omit `--provenance` from the publish step; they still get wrangle's L3 bundle in `metadata/npm/<shortname>/` and at the GitHub Release, and consumers can verify against that bundle independently of the registry.

## Implementation notes

Practical things the implementer will hit. Not contract-design speculation; that's [#171](https://github.com/TomHennen/wrangle/issues/171).

- **`build.sh` outline:**
  1. Validate inputs via `lib/validate_path.sh`. **Also reject `package.json` with a `workspaces` field** (`jq -r 'has("workspaces")' package.json` → `"true"` is a hard failure with a clear error). v0.1 single-package only.
  2. `npm ci` (lockfile-faithful install; not `npm install`). Pass `--ignore-scripts` if the `ignore-scripts` input is `true`.
  3. If `ignore-scripts` is `true`, skip steps 3 and 4 entirely — the all-or-nothing semantics mean no package.json script runs. Otherwise:
     a. If `package.json`'s `"scripts.build"` exists: `npm run build`. Conditional via `jq -r '(.scripts // {}) | has("build")'` rather than catching `npm run`'s missing-script exit code (clearer logs; null-safe against `"scripts": null`).
     b. If `"scripts.test"` exists and isn't the default no-op: `npm test`. Default-detection uses substring match against `*'no test specified'*` so minor wording tweaks in future npm releases don't accidentally re-enable the no-op.
  4. `npm pack --pack-destination dist` to produce `<name>-<version>.tgz` (scoped: `<scope>-<name>-<version>.tgz`) directly into `dist/`. Pass `--ignore-scripts` if the `ignore-scripts` input is `true`.
  5. Locate the produced tarball via a glob over `dist/*.tgz`, asserting exactly one match. Channel-free (no `tail -n1` of mixed stdout/stderr) and explicit fail-on-multi catches surprise multi-build scenarios early.
  6. SHA-256 the tarball; emit base64 `sha256:HASH FILENAME` hashes as the `hashes` output. The reusable workflow derives the per-artifact VSA matrix from it; the provenance subjects themselves come from `actions/attest-build-provenance`'s `subject-path dist/*`.
  7. `syft dir:<path> -o spdx-json` to produce `sbom.spdx.json` (Cosign-keyless-verified install via `tools/syft/install.sh`, same as python).
  8. OSV-Scanner against the lockfile.
  9. Write the unified `metadata/npm/<shortname>/` directory: `sbom.spdx.json`, `vuln-scan.json`, `summary.md`, `outputs.txt`.
- **Reusable workflow shape mirrors python's:**
  1. `build` job runs the composite (steps above), uploads `npm-dist-<shortname>` and `npm-metadata-<shortname>` artifacts.
  2. `gate` job runs `actions/release_gate` and exposes `should-release`.
  3. `attest` job (gated on `should-release`) runs `actions/attest-build-provenance` with `subject-path: dist/*` and uploads the signed bundle. Export the bundle's artifact name as `provenance-artifact-name` so it can be downloaded by name.
  4. `vsa` job (gated on `should-release`) runs `actions/verify` per dist artifact: ampel verifies the provenance against the wrangle PolicySet (fail-closed against `common.identities` + the SLSA tenets), emits the signed SLSA VSA, and attaches it to the release on tag pushes. Verify failure fails the workflow; the adopter's publish (gated on `needs:`) is blocked.
- **Reflection on `package.json`.** Steps 3 and 4 are conditional on `"scripts.build"` and `"scripts.test"` being defined. Use `jq` against `package.json` rather than running `npm run build` and catching the "missing script" exit code — clearer logs.
- **`actions/setup-node`** is the standard glue for getting Node and the `.npmrc` `registry-url` wired correctly. It belongs in the example workflow's setup, not in wrangle's `build.sh`.
- **GitHub now blocks** ([Sep 2023 changelog](https://github.blog/changelog/2023-09-27-block-npm-package-publishes-when-names-and-versions-dont-match-between-manifest-and-tarball-package-json/)) publishes where the manifest's `name`/`version` mismatches the tarball's internal `package.json` — the `npm pack` → hash → `npm publish` sequence binds cleanly.
- **Tarball name normalization** for scoped packages: `@scope/name` becomes `scope-name-version.tgz`. The build script does not need to compute the expected filename — the `dist/*.tgz` glob (single-tarball assertion) finds it deterministically.
- **Publish job in the example workflow** runs `npm publish "dist/${TARBALL}" --provenance --access public` (`TARBALL` passed via `env:`, never via direct `${{ ... }}` interpolation in the `run:` body — see CLAUDE.md "GitHub Actions Expression Injection") with `permissions: { id-token: write, contents: read }`. The `--provenance` flag is implicit under trusted publishing (auto-on) but harmless to pass explicitly. Adopters publishing to private registries drop the `--provenance` flag — they still have wrangle's L3 attached to the GitHub release on tag pushes.
- **Permissions parallel python's:** `build` job needs only `contents: read`; `attest` job needs `id-token: write`, `attestations: write`, `contents: read`; `vsa` job needs `id-token: write` and `contents: write` (the last to attach the VSA to the release on tag pushes). Callers must grant the union, including `contents: write`. Note there is no `actions: read` — that was the former generator's requirement.

## Open questions

- **Resolved: `npm publish --provenance-file` will not accept wrangle's L3 bundle.** Two structural blockers, neither in scope for wrangle to fix. (1) Client-side validation in [`libnpmpublish/lib/provenance.js`](https://github.com/npm/cli/blob/latest/workspaces/libnpmpublish/lib/provenance.js) requires `subject.name` to be a `pkg:npm/<name>@<version>` PURL with `subject.digest.sha512`; wrangle's provenance (like the former generic generator's) carries bare artifact filenames with `sha256`, so the bundle is rejected before it leaves the runner. (2) The npm registry's [server-side validation](https://github.com/npm/provenance/blob/main/README.md) binds the Fulcio signing cert's `Build Signer URI` / `Source Repository URI` extensions to the package's own `repository` field; wrangle's provenance cert points at `TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml@…` (its builder identity), which won't match the caller's `repository`. Closing the gap would require either npm-shaped subjects + caller-repo Fulcio identity, or changes in npm's registry validation. The SLSA Node.js builder is purpose-built to clear both, which is why it's the only documented producer for `--provenance-file` today. **Implication for wrangle:** the Node.js builder remains the only path to populate the registry slot with L3; wrangle's L3 stays as a wrangle-owned bundle artifact (and the VSA on the release) regardless. The design pick (wrangle L3 as a separate artifact + npm L2 in registry slot) is not a hedge — it is the only structurally available option short of importing the Node.js builder's beta envelope.
- **Resolved: `npm sbom` SPDX conformance was contested → switched to `syft`.** The OWASP CycloneDX project lead's critique applied to `npm sbom`'s CycloneDX output; the SPDX output's conformance was contested rather than settled. Rather than ship with an open conformance question, v0.1 picks `syft` (already in wrangle's tool inventory, used by python; OWASP-known-conformant for SPDX). The contract — "wrangle produces a good SPDX SBOM" — is unchanged.
