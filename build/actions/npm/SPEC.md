# Wrangle npm Build Type — Phase 1 Research

This document captures Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md).

**Status:** research only. No implementation has been written. No `action.yml`, no reusable workflow, no example workflow, no test fixture. The build-type adapter contract being discussed in [#171](https://github.com/TomHennen/wrangle/issues/171) is not committed; this document is one of three ecosystem inputs (alongside Go and generic) intended to inform that contract design.

## Design principles

The runbook's Phase 1 question list is the frame. Where a fact is unverified or a primary source could not be located in the time available, that is called out explicitly rather than papered over.

### Canonical build tool(s)

The npm ecosystem has three first-class package managers:

- **npm** (the reference implementation, ships with Node.js).
- **pnpm** (`pnpm/pnpm`) — content-addressed `node_modules`, first-class workspaces.
- **Yarn** — historically Yarn 1.x ("classic"), now superseded by Yarn 4 / "Berry" (`yarnpkg/berry`).

Detection rules in the wild key off lockfiles:

- `package-lock.json` → npm
- `pnpm-lock.yaml` → pnpm
- `yarn.lock` → Yarn (1.x or Berry; differentiated by `.yarnrc.yml` presence and the `packageManager` field in `package.json`)

If multiple lockfiles are present, projects typically commit only one and `.gitignore` the others; `package.json`'s `packageManager` field (e.g., `"packageManager": "pnpm@9.0.0"`) is the modern authoritative declaration ([Corepack proposal](https://github.com/nodejs/corepack)).

For the wrangle Phase 1 question — "which to support first?" — the relevant filter is **which package managers can produce a provenance-attested publish today.** Provenance support is asymmetric across the three managers and that asymmetry is load-bearing:

| Manager | `--provenance` support | Notes |
|---|---|---|
| npm | yes (since npm 9.5.0) | reference path; auto-on under trusted publishing in npm CLI 11.5.1+ |
| Yarn (Berry) | yes, in v4.9+ | per [yarnpkg/berry#5430](https://github.com/yarnpkg/berry/issues/5430) — `yarn npm publish --provenance` and `publishConfig.provenance` |
| pnpm | open feature request | [pnpm/pnpm#6435](https://github.com/pnpm/pnpm/issues/6435) — adopters publishing pnpm workspaces typically build with pnpm and publish each package with `npm publish --provenance` |

This matters more than the build-tool choice. Most projects use the same manager to install, build (`<mgr> run build`), pack, and publish — but the *publish* step is what the registry treats as authoritative, and that is where provenance attaches. The pragmatic narrowing for a v0.1-shaped npm build type is to support `npm` first (broadest, most mature), with a defined fallback to `npm publish` for projects whose install/build manager is pnpm.

**Sources:** [npm CLI docs](https://docs.npmjs.com/cli/v11/commands/npm-pack), [yarn berry issue #5430](https://github.com/yarnpkg/berry/issues/5430), [pnpm issue #6435](https://github.com/pnpm/pnpm/issues/6435).

### Canonical SBOM tool

npm ships an in-tree SBOM generator, `npm sbom` ([npm docs](https://docs.npmjs.com/cli/v11/commands/npm-sbom/)), available since npm 10. It can emit either CycloneDX (default) or SPDX via `--sbom-format=spdx`, with `--sbom-type` and `--omit` flags for tuning scope (`dev`, `optional`, `peer`).

Two caveats from the ecosystem:

1. **Format-correctness disputes.** The OWASP CycloneDX project lead has publicly stated `npm sbom` "does not respect the CycloneDX specification" in some respects (registry integrity hashes placed on components rather than as distribution metadata; silent license-parsing dropouts). For SPDX output the equivalent claim is less prominent, but `npm sbom`'s spec conformance is contested rather than settled. *(Source surfaced in search; primary statement could not be independently verified within the research window — flagged as unverified, not load-bearing.)*
2. **External alternatives exist** and are often preferred:
   - [`@cyclonedx/cyclonedx-npm`](https://www.npmjs.com/package/@cyclonedx/cyclonedx-npm) — OWASP-maintained CycloneDX generator specifically for npm projects.
   - [`syft`](https://github.com/anchore/syft) — Anchore's general-purpose SBOM tool (already used by wrangle for python; produces SPDX). Walks `node_modules/` or `package-lock.json`.
   - [`cdxgen`](https://github.com/CycloneDX/cdxgen) — multi-ecosystem CycloneDX generator covering npm, pnpm, yarn, and lockfile flavors.

Wrangle has standardized on **SPDX** ([`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout"). The two viable paths for an npm build type:

- **`npm sbom --sbom-format=spdx`** — in-tree, no extra tool to install/verify, but conformance is contested and behavior is npm-specific (won't work cleanly for projects whose lockfile is `pnpm-lock.yaml` or `yarn.lock` without first running `npm install` against `package-lock.json`, which they may not have).
- **`syft` against the project directory** — already in wrangle's tool inventory (`tools/syft/`), already SPDX-native, package-manager-agnostic. Costs a tool install per build.

Phase 1 does not have to choose, but the research here suggests `syft` wins on consistency-with-python and manager-agnosticism unless `npm sbom`'s conformance issues turn out to be paper-only.

**Sources:** [`npm-sbom` docs](https://docs.npmjs.com/cli/v11/commands/npm-sbom/), [cyclonedx-node-npm](https://github.com/CycloneDX/cyclonedx-node-npm).

### Canonical publish target

**npmjs.org** is the dominant target by an enormous margin. Two secondary targets exist:

- **GitHub Packages npm registry** (`npm.pkg.github.com`) — sometimes used for private/internal packages. Provenance support here is unclear; the npm provenance docs explicitly call out `registry.npmjs.org` and GitLab, not GitHub Packages.
- **Self-hosted registries** (Verdaccio, Artifactory, Nexus). Provenance against these is not supported by upstream tooling — the Sigstore-bundle-to-registry handoff is wired into npmjs.org specifically.

For wrangle's purposes, "npm" effectively means "publish to npmjs.org with provenance" today. Adopters publishing to private/internal registries are a contract edge case that resembles the python "private registry" gap (also unsupported in v0.1).

**Source:** [npm Generating provenance statements](https://docs.npmjs.com/generating-provenance-statements/).

### Canonical attestation pattern

This is the most contract-relevant section. **npm provenance** ([`npm publish --provenance`](https://docs.npmjs.com/generating-provenance-statements/), GA April 2023) is the npm ecosystem's native attestation, and it is structurally different from the patterns wrangle has integrated for container and python.

**What `--provenance` actually emits.** An in-toto Statement (`_type: https://in-toto.io/Statement/v0.1`) carrying a SLSA Provenance predicate. The predicate version is **`https://slsa.dev/provenance/v0.2`** ([npm/provenance README](https://github.com/npm/provenance), [GitHub blog](https://github.blog/security/supply-chain-security/introducing-npm-package-provenance/)). A search result indicated v1.0 predicate support is *also* accepted by the registry from GitHub Actions; the published-by-npm-CLI default predicate version is v0.2 today.

**Where it lives.** Three locations:

1. **Sigstore Rekor** — Sigstore-signed bundle uploaded to the public transparency log.
2. **The npm registry** — attached to the published package version; visible as a "Built and signed on GitHub Actions" badge on the package's npmjs.com page and retrievable via the registry API.
3. *(Implicitly)* the issuing GitHub Actions run's logs, which the provenance references via `invocation.configSource.uri` and `invocation.configSource.entryPoint`.

**Verification.** Consumers run `npm audit signatures` ([npm docs](https://docs.npmjs.com/generating-provenance-statements/)). The command invokes `sigstore.verify` on each Sigstore bundle, then asserts the in-toto `subject.name` and `subject.digest.sha512` match the installed tarball — i.e., it covers both the signature *and* the binding to the actual bytes a consumer just downloaded. `cosign verify-bundle` also works against the Sigstore bundle ([Sigstore blog](https://blog.sigstore.dev/cosign-verify-bundles/)). There is no widely-deployed `slsa-verifier` path for npm provenance today; SLSA verification is implicitly bundled into `npm audit signatures`.

**SLSA level.** Multiple sources describe `--provenance` as producing "SLSA-compliant" or "verifiable" provenance, but the **explicit SLSA level claim is murky**. The GitHub blog announcement does not name a level; the npm docs do not name a level. The closest formal claim is from the SLSA Node.js builder (see next paragraph), which does claim Build L3. The plain `npm publish --provenance` path likely sits below L3 because the build is not isolated in a non-falsifiable builder — it runs on the adopter's own GHA runner with the adopter's full workflow context. *(Treating this as load-bearing-but-unverified for the contract design: if `--provenance` is < L3, then wrangle layering `slsa-github-generator` on top *is* additive, not redundant. If it is L3, it is redundant for npm.)*

**The SLSA Node.js builder.** [`slsa-framework/slsa-github-generator/internal/builders/nodejs`](https://github.com/slsa-framework/slsa-github-generator/tree/main/internal/builders/nodejs) ships a separate reusable workflow (`builder_nodejs_slsa3.yml`) that runs the npm build inside the SLSA generator's isolated builder and emits SLSA Build L3 provenance with the SLSA `delegator-generic@v0` buildType. As of April 2026 this builder is **still in beta** ([Node.js Builder GA milestone](https://github.com/slsa-framework/slsa-github-generator/milestones)) and has explicit limitations:

- npm-only for builds (yarn, pnpm, lerna unsupported as builders).
- **Workspaces unsupported** ([slsa-github-generator#1789](https://github.com/slsa-framework/slsa-github-generator/issues/1789)).
- Predicate is SLSA v0.2 (same as the in-CLI path).
- Constrained event support — no `pull_request`.

It composes with `npm publish --provenance` as either-or, not both: the Node.js builder's reference flow uses its own `nodejs/publish` action, but adopters can use the builder for the build-and-attest step and then publish the produced tarball independently.

**The structural difference vs. python and container.** Python and container both have an ecosystem-native attestation (PEP 740, OCI image attestation) AND wrangle layers `slsa-github-generator` provenance on top. Both attestations end up in the consumer's reach, answering different questions. **For npm, `--provenance` already *is* a SLSA-shaped attestation** signed via Sigstore and stored in the consumer-facing path. Layering `slsa-github-generator` on top is not obviously additive in the same way:

- If the goal is "stronger isolation guarantee" — the SLSA Node.js builder *is* `slsa-github-generator`. Adopting it replaces `--provenance` rather than augmenting it.
- If the goal is "SLSA L3 provenance discoverable via `slsa-verifier` against a non-OCI artifact" — the existing `generator_generic_slsa3.yml` path used by python could in principle be applied to the `npm pack` tarball. This would produce a second, parallel attestation alongside `--provenance`.

This is the central question for #171's contract: **does an "npm" build type integrate with the Node.js builder, with the generic generator over a packed tarball, or with neither (relying on `--provenance` alone)?** The runbook ("each build type integrates with the ecosystem-native pattern *and* layers SLSA L3 provenance on top") presupposes a yes-and answer, but for npm the ecosystem-native pattern *is* a SLSA attestation, so "and" needs a definition.

**Sources:** [GitHub blog: Introducing npm package provenance](https://github.blog/security/supply-chain-security/introducing-npm-package-provenance/), [npm/provenance](https://github.com/npm/provenance), [SLSA Node.js builder docs](https://github.com/slsa-framework/slsa-github-generator/tree/main/internal/builders/nodejs), [Cosign verify bundles](https://blog.sigstore.dev/cosign-verify-bundles/).

### Authentication model

npm has **trusted publishing with OIDC**, generally available since **31 July 2025** ([GitHub changelog](https://github.blog/changelog/2025-07-31-npm-trusted-publishing-with-oidc-is-generally-available/), [npm docs](https://docs.npmjs.com/trusted-publishers/)). This is the modern, recommended path and structurally mirrors PyPI Trusted Publishing.

**Mechanics:**
- Adopter configures a "trusted publisher" on npmjs.com → Packages → `<package>` → Settings → Trusted publishing, pinning a GitHub repository, workflow filename, and optional environment.
- The publish workflow grants `id-token: write`, runs `actions/setup-node` with `registry-url: 'https://registry.npmjs.org'`, then runs `npm publish` (no `NODE_AUTH_TOKEN`, no `NPM_TOKEN`).
- The npm CLI exchanges the GHA OIDC token for a short-lived publish credential automatically.
- **Provenance is auto-on under trusted publishing** — `--provenance` is implicit; adopters don't pass the flag.

**Constraints:**
- **npm CLI ≥ 11.5.1** and **Node ≥ 22.14.0** (per the trusted-publishers docs as surfaced).
- **GitHub-hosted runners only** for both Actions and GitLab. Self-hosted runners are explicitly excluded for trusted publishing.
- **Provenance is unavailable for packages whose source repo is private** (per the GA changelog).
- **One trusted publisher per package** at a time (must reconfigure to switch).

**Legacy path** — `NPM_TOKEN` granular tokens (or classic automation tokens) — remains supported. The token is set as `NODE_AUTH_TOKEN` in the publish step's env. This is the only option for adopters who can't or won't move to trusted publishing (private-repo provenance gap; non-GHA non-GitLab CI; npm CLI < 11.5.1; etc.).

**Initial publish gap.** Trusted publishing **cannot publish a package's first version** ([npm/cli#8544](https://github.com/npm/cli/issues/8544)) — the publisher must already exist as a trusted-publisher relationship, which requires the package to exist. The bootstrap is a manual `npm publish` from a maintainer's terminal (or a token-based first publish).

**Sources:** [npm Trusted publishers](https://docs.npmjs.com/trusted-publishers/), [GA changelog 2025-07-31](https://github.blog/changelog/2025-07-31-npm-trusted-publishing-with-oidc-is-generally-available/), [npm/cli#8544](https://github.com/npm/cli/issues/8544).

### Reference workflow patterns

Three reference workflow shapes seen in popular projects:

1. **`npm publish --provenance` direct.** The minimum viable provenance flow:
   ```yaml
   permissions:
     contents: read
     id-token: write   # OIDC for Sigstore
   steps:
     - uses: actions/checkout@<sha>
     - uses: actions/setup-node@<sha>
       with: { node-version: '20.x', registry-url: 'https://registry.npmjs.org' }
     - run: npm ci
     - run: npm run build      # if applicable
     - run: npm publish --provenance --access public
       env: { NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }} }   # absent under trusted publishing
   ```
   This is the canonical shape promoted by the npm docs and the GitHub blog. Most projects publishing with provenance today match it.

2. **`changesets/action`-driven.** Sigstore's own [`sigstore/sigstore-js`](https://github.com/sigstore/sigstore-js) repo wraps `npm publish` (called as `npm run release` from a `changesets/action@v1` step). The release script is responsible for invoking `npm publish --provenance` per workspace; the workflow just supplies `id-token: write` and `NODE_AUTH_TOKEN`. No `slsa-github-generator` invocation. Workspaces are handled by changesets itself, not by the workflow.

3. **`semantic-release`-driven.** Conceptually the same as changesets — the release tool determines version, publishes, and attaches provenance internally. The CI workflow stays minimal.

**Common factors:**
- `id-token: write` is universal once provenance is in scope.
- `actions/setup-node` with an explicit `registry-url` is universal (it's how `.npmrc` ends up wired correctly).
- `npm ci` (not `npm install`) before build — lockfile-faithful install.
- A separate `build` step (running whatever `package.json`'s `"build"` script defines) is conditional on the project actually having one. Lots of npm packages publish source JS unbuilt; many publish TypeScript-compiled output; the workflow rarely *cares* which because it's just running `npm run build` if defined.
- **None of the popular reference workflows reviewed invoke `slsa-github-generator` alongside `--provenance`.** The community has converged on `--provenance` as sufficient.

**Source:** sigstore/sigstore-js release workflow (reviewed via WebFetch); npm docs reference example; GitHub blog example.

### Where artifact identity emerges (#171-relevant)

`npm pack` produces a deterministically named tarball **before publish**: `<name>-<version>.tgz` (scoped packages: `<scope>-<name>-<version>.tgz` after npm normalizes the scope's `@`/`/`). Hash-based identity is therefore available at build time, exactly like python's `dist/*.whl` and `dist/*.tar.gz` artifacts.

This is **unlike container**, which only gets a digest after `docker push`. The npm contract can hash the tarball pre-publish without inverting the build/publish ordering.

Worth noting: GitHub now (as of Sep 2023, [changelog](https://github.blog/changelog/2023-09-27-block-npm-package-publishes-when-names-and-versions-dont-match-between-manifest-and-tarball-package-json/)) blocks publishes where the manifest's `name`/`version` mismatches the tarball's internal `package.json`. The `npm pack` → hash → `npm publish` sequence is the same artifact in both steps; subjects-by-hash bind cleanly.

The npm provenance attestation already covers `subject.digest.sha512` of the tarball ([Cosign verify bundles blog](https://blog.sigstore.dev/cosign-verify-bundles/)), so wrangle does not need to re-hash to make `--provenance` work — but it does need to hash if it wants to feed `slsa-github-generator`'s `base64-subjects` input for a parallel attestation.

### What the ecosystem expects wrangle to provide vs. delegate (#171-relevant)

The implicit ecosystem expectation, from the reference workflows, is roughly:

| Step | Ecosystem expects from CI | Wrangle delegate or own? |
|---|---|---|
| Install Node + set registry URL | `actions/setup-node` | delegate (existing pattern) |
| Install deps | `npm ci` | delegate (one line) |
| Build | `npm run build` (project-defined) | **delegate, with caveats — see "user-supplied build" below** |
| Test | `npm test` | delegate (one line) |
| SBOM | not standard in the workflow today; usually post-hoc | **wrangle owns** (consistent with python/container) |
| SBOM scan | not standard | wrangle owns |
| Pack | `npm pack` (or implicit in publish) | wrangle owns the explicit pack step to get hashes |
| Sign / attest | `npm publish --provenance` (one flag) | **see "Canonical attestation pattern"** — likely wrangle delegates to `--provenance` rather than layering |
| Publish | `npm publish` | **adopter's own workflow**, mirroring python — trusted publishing's OIDC `workflow_ref` is bound to the caller, not the reusable workflow ([pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096) is python; the npm trusted-publishing constraint is the same shape per [npm trusted-publishers docs](https://docs.npmjs.com/trusted-publishers/)) |

The biggest open question is "what does wrangle own that `npm publish --provenance` doesn't already give an adopter?" Candidates:

- **SBOM generation and vulnerability scanning** — `--provenance` does not emit an SBOM. Wrangle's existing SPDX + osv-scanner pipeline is a clear addition.
- **Test gating before publish** — `--provenance` does not enforce test pass.
- **Consistent metadata directory** (`metadata/npm/<shortname>/`) for cross-ecosystem audit tooling.
- **Pre-publish verification** — wrangle's python pattern of `slsa-verifier verify-artifact` between build and publish has no obvious npm equivalent because verification is post-publish (`npm audit signatures` requires the registry-side state). Whether there's a wrangle-owned pre-publish verify for npm is genuinely unclear.
- **Hash-pinned dist-artifact handoff** — passing the packed tarball as a workflow artifact from build to the adopter's publish job means the adopter is publishing exactly what wrangle hashed and SBOMed, not whatever `npm pack` re-emits.

What wrangle should *not* re-implement is the Sigstore-bundle-to-registry path itself. That's npm CLI's job and npm CLI does it correctly today.

### Whether the build is wrangle-invoked or user-supplied (#171-relevant)

**Build is user-supplied.** `npm run build` runs whatever `package.json`'s `"scripts.build"` field says — it could be `tsc`, `webpack`, `vite`, `esbuild`, `rollup`, `babel`, `tsup`, `swc`, `parcel`, or the empty string. There is no canonical builder the way `python -m build` is canonical.

This pushes npm structurally closer to the **generic** build type than to python:

- python knows the build command (`python -m build` or `uv build`) and the output location (`dist/`).
- container knows the build command (`docker buildx build`) and output (the registry-bound digest).
- npm does **not** know the build command. It knows that `npm run build` is the convention if a build is needed at all, and that `npm pack` produces the tarball regardless.

A subtlety: many npm packages have *no* `build` step. They publish source JavaScript unbuilt. `npm pack` works correctly with or without a prior build — it consumes whatever `package.json`'s `"files"` field (or `.npmignore`) says is in-scope.

**Implication for the contract.** A `build.sh` for npm probably runs:
1. `npm ci` (lockfile-faithful install)
2. `npm run build` *if `"scripts.build"` exists*
3. `npm test` *if `"scripts.test"` exists and isn't the default no-op*
4. `npm pack` to produce the tarball
5. Hash the tarball

Step 2 is reflective on `package.json`. The contract surface here is "let `package.json` decide what build means." That is a thinner ecosystem assumption than python's "PEP 517 backend produces wheel + sdist," and almost as thin as generic's "user names a command."

### Awkward cases (#171-relevant)

A non-exhaustive list of cases the contract may need to bend for, surfaced from the research:

- **Workspaces / monorepos.** A single repo with `workspaces: ["packages/*"]` produces N tarballs from one build. The current python-shaped contract assumes one path → one build → one set of artifacts. The SLSA Node.js builder explicitly does not support workspaces ([#1789](https://github.com/slsa-framework/slsa-github-generator/issues/1789)). `npm publish --provenance` works per-workspace but requires N separate publish invocations. Tools like [changesets](https://github.com/changesets/changesets), [Lerna](https://lerna.js.org/), [Nx](https://nx.dev/), and [Turborepo](https://turbo.build/) coordinate the multi-package release; they're effectively a layer above what wrangle would integrate.
- **Pre/postpublish hooks.** `package.json` lifecycle scripts (`prepublish`, `prepublishOnly`, `prepack`, `postpack`, `prepare`) run during `npm publish` and `npm pack`. They can rebuild, transpile, or modify what's in the tarball *between* wrangle's hash step and `npm publish`'s actual upload. **This is a real attack surface.** The mitigation pattern in the ecosystem is `npm pack` followed by `npm publish <packed-tgz>` — the tarball is bytes-stable across the boundary and `prepublish` hooks don't re-fire on a tarball-direct publish.
- **TypeScript transpilation.** Many packages publish compiled output (`dist/`) rather than source. The compile step is part of `npm run build`; wrangle treats it as opaque.
- **Dual ESM/CJS.** Increasingly common; orthogonal to wrangle but constrains what `npm pack` packages.
- **Scoped packages.** `@scope/name` requires `npm publish --access public` for the first publish (npm defaults scoped packages to private-paid). Adopters miss this constantly.
- **Initial publish.** As above — trusted publishing can't bootstrap a package's first version. Adopters need to manually `npm publish` once before wrangle's automated path works.
- **Pre-release / dist-tags.** `npm publish --tag beta` publishes under a non-`latest` dist-tag. The contract should let adopters control this without wrangle re-implementing tag logic.
- **Native modules / `node-gyp`.** Some packages (e.g., `bcrypt`, `node-sass`-era projects) compile native code. SBOM coverage for the C/C++ portion is a separate problem; `syft` can see Node modules but the compiled binaries' provenance is its own thing.
- **Private registries.** Provenance does not work against `npm.pkg.github.com`, Verdaccio, Artifactory, or Nexus. Adopters publishing privately get the build pipeline but not the attestation surface — same shape as python's "no Trusted Publishing for private PyPI" gap.
- **`prepare` script in dependencies.** Transitive dev-dep `prepare` scripts run during `npm ci`. `npm ci --ignore-scripts` is the safer default for CI but breaks projects whose own build relies on a dep's prepare. There is no clean answer.

## Notes for #171 contract design

These are the points from the research most likely to stress or inform the build-type adapter contract being discussed in #171. Documented as observations, not as design proposals.

1. **The ecosystem-native attestation already is SLSA-shaped.** Container's OCI image attestation and python's PEP 740 attestation answer different questions than SLSA provenance, so wrangle's "ecosystem-native + SLSA L3" framing is genuinely additive for those. For npm, `npm publish --provenance` is itself a SLSA-predicate Sigstore-signed in-toto attestation, verified by `npm audit signatures` against a Sigstore bundle. Adding `slsa-github-generator` on top is either a duplicate (same predicate, different signer) or a substitution (use the SLSA Node.js builder *instead* of `--provenance`). The contract assumption that every build type composes both layers may not hold cleanly here.

2. **Trusted-publishing's caller-OIDC constraint repeats the python pattern.** Publish must live in the adopter's workflow, not in wrangle's reusable workflow, for the same `workflow_ref` reason ([pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096) — npm has the structural equivalent). The python-style split (build + provenance + verify in the reusable; publish in the caller) transfers directly. Whether the verify step transfers is the open question — see (4) below.

3. **Build is user-defined.** `npm run build` is whatever `package.json` says, and a fraction of packages have no build step at all. This is closer to the generic pattern than to python or container. A `build.sh` contract that takes `<src_dir>` and produces a hashed artifact at `<output_dir>` works, but the "what to run" is reflective on `package.json` rather than baked into the build type. This is a useful contract stress-test: if the contract can express "run `npm run build` if present, else skip, then `npm pack`," it can probably express the generic case too.

4. **Pre-publish verification is structurally awkward.** Python's wrangle-owned `slsa-verifier verify-artifact` step closes a "tampered between build and publish" window using the SLSA generator's offline-verifiable provenance. For npm, the equivalent verifier (`npm audit signatures`) requires the registry-side state, which only exists after publish. Verifying the locally-packed tarball matches what `--provenance` will eventually attest is possible (run `npm publish --dry-run`? hash the tarball pre/post?) but doesn't have an obvious community-blessed shape. The contract may need an explicit "verify is not always pre-publish" affordance.

5. **Workspaces / monorepos break the one-path-one-artifact assumption.** The current python-style contract maps `path: pkg/foo` to one build, one set of dist artifacts, one `<shortname>`. An npm workspace at the repo root produces N tarballs from one build. Either the contract handles fan-out (and `<shortname>` becomes per-package, not per-path), or wrangle initially supports only "single-package npm" and relegates workspaces to a future iteration — the way it relegates multi-arch container builds today.

6. **The packed-tarball boundary is a useful publish-asymmetry resolution.** Issue #171's "(A) artifact-identity boundary" maps to `npm pack` cleanly: the tarball exists locally, hashes are computable, the same bytes can be uploaded by `npm publish <tgz>`. That sidesteps `prepack`/`prepublish` hook re-runs between wrangle's hashing and publish's upload. So for npm specifically, option (A) doesn't require pushing inside `build.sh` the way container does — `npm pack` is wholly local. This is mild evidence that the python-style "produce local artifacts, hash, hand off" boundary is the more general shape, and container is the exception (forced by OCI), not the rule.

7. **`npm publish --provenance` is GHA-coupled by construction.** It reads `GITHUB_*` env vars to populate the SLSA predicate's `invocation.configSource` and `invocation.parameters` fields, and it requires a Sigstore-resolvable OIDC token issuer. Porting this to a non-GHA CI (#171's portability angle) means the ecosystem-native attestation itself doesn't port without registry-side and CLI-side changes. GitLab is the only other CI npm currently supports for trusted-publishing/provenance; everyone else falls back to token-based publish without provenance. This is a concrete data point that "ecosystem-native" can mean "GHA-and-GitLab-native" in practice, which the contract should not paper over.

8. **The SLSA Node.js builder is still beta.** Pinning to it for v0.1 imports a not-yet-GA dependency. The python build type pinned `slsa-github-generator`'s generic generator at a stable v2 tag; the Node.js builder's status as of April 2026 should be re-checked before any commitment. If wrangle wants L3 isolation for npm specifically, the timing matters.

## Open questions

Items the research could not resolve, called out so the next phase isn't built on assumed answers.

- **Exact SLSA level of plain `npm publish --provenance`.** Multiple sources say "SLSA-compliant"; none seen in this research explicitly name a level. If it's L1/L2, layering `slsa-github-generator` matters. If it's effectively L3 via Sigstore-keyless signing on a hosted runner, the layering is duplicative. *(The SLSA Node.js builder's L3 claim depends on builder isolation; the in-CLI path runs on the adopter's runner, which generally implies < L3, but verifying this against the SLSA spec's text was outside the time budget here.)*
- **Whether the in-CLI predicate v1.0 path is actually wired.** [npm/provenance](https://github.com/npm/provenance) suggests the registry accepts v1.0 predicates from GHA; the npm CLI's emit path documented today is v0.2. Whether both versions are produced today (and which is canonical for verifiers) wasn't fully resolved.
- **`npm sbom` SPDX conformance.** The CycloneDX project lead's critique of npm's CycloneDX output is paraphrased in secondary sources; whether SPDX output is similarly contested wasn't directly verified.
- **GitHub Packages npm registry + provenance.** The npm provenance docs explicitly call out `registry.npmjs.org` and GitLab; whether `npm.pkg.github.com` accepts provenance attachments is not covered. Likely "no" given the Sigstore handoff is npmjs.org-specific, but not confirmed.
- **Pre-publish verification analog.** Whether there's a community-recognized "verify what you're about to publish matches what `--provenance` will attest" step — or whether the entire ecosystem treats this as "publish first, then `audit signatures`" — wasn't resolvable from the materials reviewed.
