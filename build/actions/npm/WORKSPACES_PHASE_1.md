# Wrangle npm Workspaces — Phase 1 Research

**Status:** Phase 1 research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md), applied to *extending* the existing npm build type rather than introducing a new one. Recommends defaults for workspaces support in `build/actions/npm/`. **Research only** — no implementation yet; `validate_inputs.sh` continues to reject workspaces until the implementation PR lands.

Tracking: [#208](https://github.com/TomHennen/wrangle/issues/208). Companion: [#207](https://github.com/TomHennen/wrangle/issues/207) (pnpm-only single-package, lands first).

> **Note (predates #316):** this doc was written while wrangle produced L3 provenance via the `generator_generic_slsa3.yml` generic generator. As of #316 wrangle uses `actions/attest-build-provenance` run inside its reusable workflow. The multi-subject approach below still applies — `actions/attest-build-provenance`'s `subject-path`/`subject-checksums` covers N tarballs as N subjects in one bundle — but ignore the generic-generator / `base64-subjects` mechanics; the speculative plan is otherwise unchanged.

## Overview

A workspaces project is a single `package.json` with a `"workspaces": ["packages/*"]` (or equivalent) field plus multiple package directories underneath. One `npm pack`/`pnpm pack`/`yarn pack` at the workspaces root (or per-package) produces **N tarballs**, one per workspace package. This is the dominant modern-JS monorepo shape — every popular framework that ships multiple coordinated packages from one repo uses it (TanStack, Effect-TS, Babel, Material UI, Vite ecosystem, the npm-CLI itself).

Wrangle's v0.1 (`build/actions/npm`) explicitly rejects `package.json` with a `workspaces` field in `validate_inputs.sh`. The N-tarball case breaks the current single-tarball assertion at `action.yml` and propagates downstream to hashing, provenance subject lists, artifact upload, and the adopter's publish step. Adopting workspaces is therefore not a "detect a new lockfile" change like #207's pnpm-only support — it's an **artifact-model change** that touches every layer from `build_and_pack.sh` up through the example workflow.

This doc answers the Phase 1 questions for that change.

## Operating model

The same overall flow as v0.1 npm, adjusted for multiple artifacts:

1. **Validate** that `package.json` has `workspaces`, and that each workspace member directory has its own `package.json` with `name` and `version`. Lockfile detection is unchanged (npm/pnpm/yarn — pnpm support pending from #207).
2. **Install** at the workspaces root using the project's package manager (`npm ci` / `pnpm install --frozen-lockfile` / `yarn install --immutable`). Each pulls workspace deps into a single coordinated `node_modules/`.
3. **Pack** each workspace member. Strategy varies by package manager:
   - `npm pack --workspaces` packs all members into `<root>/dist/` (with the right scope-name-version naming for each).
   - `pnpm -r exec pnpm pack --pack-destination <root>/dist/` — pnpm's `pack` command itself doesn't accept `-r`; the recursive form is via `pnpm -r exec` wrapping the per-package pack. **Verify the exact invocation against current pnpm during implementation** — pnpm CLI surface shifts between minor versions.
   - Yarn Berry: `yarn workspaces foreach -A pack -o <root>/dist/<name>.tgz` or similar (pending verification — see open questions).
4. **Hash** all tarballs in `<root>/dist/` and emit a multi-subject `base64-subjects` for the SLSA generator.
5. **Generate provenance** via `generator_generic_slsa3.yml` with the multi-subject input. ONE bundle attesting N artifacts.
6. **Verify** all tarballs against the multi-subject bundle in a single `slsa-verifier verify-artifact ... dist/*` invocation (matches python's existing wheel+sdist verify pattern — not an N-call loop).
7. **Publish** in the adopter's caller workflow — iterate over the N tarballs, publish each with appropriate per-package `--access` and `--tag` flags.

Most of the structural changes are at steps 3-5 (artifact count cascades through hash, SBOM, and provenance). Steps 1-2 are localized validation/install changes. Steps 6-7 fan out per-tarball but stay shaped the same per-tarball.

## Recommended defaults (the picks)

### Detection — `package.json` `"workspaces"` field

- **Pick:** Detect workspaces by `jq -r 'has("workspaces")' package.json` returning `true` (the same check `validate_inputs.sh` already uses to *reject*, inverted).
- **Variants:**
  - `pnpm-workspace.yaml` (pnpm's separate workspace declaration) — also accept. Either or both can be present; presence of either triggers workspaces mode.
  - Yarn Berry's `workspaces` field in root `package.json` is the same shape as npm's; same detection.
- **Edge case:** `"workspaces": []` (empty) → reject as malformed. `"workspaces": "packages/*"` (string instead of array, legacy npm 7+ form) → accept; npm CLI itself accepts both shapes.

### Per-workspace member validation

- **Pick:** Each workspace directory listed in the resolved expansion must have its own `package.json` with both `name` and `version` fields. Reject early if any member is malformed, since `npm pack --workspaces` would silently skip malformed entries (a footgun where adopters expect N tarballs and get N-1).
- **Implementation:** Use `npm query` or equivalent to enumerate the resolved workspaces, then `jq` per member. Reject with one error message listing all offending members.
- **`private: true` filtering is mandatory at this step, not just at pack time.** The expected-count check downstream compares pack output against the enumerated workspace set; if `private: true` members are in the set but excluded from pack, the count fails for every adopter who has private fixtures or examples. Filter them out *here*, when establishing the expected N:
  ```
  expected_count=$(jq '[.workspaces[] as $w | input_filename | ... | select(.private != true)] | length' …)
  ```
  Same filtering applies regardless of enumeration mechanism — `npm query` returns the resolved set including private packages, so the filter is needed in that path too.

### Pack invocation — manager-specific

- **npm:** `npm pack --workspaces --pack-destination dist/` (npm 7+ supports `--workspaces`). Honor adopter's `ignore-scripts: true` opt-in. Writes `<scope>-<name>-<version>.tgz` per package.
- **pnpm:** `pnpm -r exec pnpm pack --pack-destination <root>/dist/`. pnpm's `pack` command operates on the current package only — `-r` does NOT accept `pack` directly per pnpm's CLI docs (the recursive flag's supported-command allowlist is install/update/run/test/exec/publish/etc., not pack). The recursive-pack idiom is `pnpm -r exec` wrapping the per-package `pnpm pack`. Confirm the exact invocation against the pnpm version pinned at implementation time.
- **yarn:** Defer to #207's pnpm work landing first; yarn variant is third in line. Phase 1 design assumes the same shape (one invocation produces N tarballs in dist/).

### Tarball discovery — glob and count

- **Pick:** After pack, glob `dist/*.tgz` and assert the count matches the expected number of workspace members. Specifically:
  - Enumerate expected members from `package.json` (post-glob-expansion).
  - Count actual `.tgz` files in `dist/`.
  - If counts differ, fail with both lists for debugging.
- **Why:** Catches the "npm pack silently skipped a malformed member" case and the "adopter's `files:` config produced an empty tarball" case (npm pack still writes the file, just an empty one — adopters need to see this fail loudly).

### Hash and subject list — multi-subject SLSA generator input

- **Pick:** Emit `base64-subjects` with N entries, one per tarball, using the format the generic generator expects:
  ```
  <sha256-hex>  <filename>
  <sha256-hex>  <filename>
  ...
  ```
  base64-encoded as a single string (multi-line input, base64 of the concatenation including newlines). This matches python's existing multi-artifact pattern (wheel + sdist) which already uses multi-subject base64-subjects today.
- **Implementation note:** `cd dist/ && sha256sum -- * | base64 -w0` produces the right output as long as the listing is deterministic. Sort by filename for reproducibility, and **force the C locale** so character collation doesn't drift across CI runner locales: `cd dist/ && sha256sum -- $(ls -1 *.tgz | LC_ALL=C sort) | base64 -w0`. Without `LC_ALL=C`, runners with different default locales (e.g., `en_US.UTF-8` vs `C.UTF-8`) can order punctuation-containing filenames differently, producing different base64-subjects bytes for the same N artifacts. `npm pack` happens to strip `@` from scoped names today (`@scope/foo` → `scope-foo-1.0.0.tgz`), but yarn berry's naming may differ and future tooling could re-introduce specials — `LC_ALL=C` is zero-cost insurance. **Divergence from python:** python's existing hash step uses bare `sha256sum -- *` (no explicit sort, no `LC_ALL=C`), which is fine for N=2 wheel+sdist where the glob expansion is predictable. Workspaces has unbounded N; explicit sort + C locale is required for byte-identical hashes across re-runs. (Worth a follow-up to apply the same hardening to the python hash step — invisible today at N=2, but the principle generalizes.)

### Provenance bundle — one wrangle L3 bundle (N subjects), paired with N per-package L2 in-CLI attestations

- **Pick:** Single `provenance-name: npm-<shortname>.intoto.jsonl` bundle attesting all N artifacts as separate subjects. The generic generator handles this natively — `base64-subjects` with N entries produces a single in-toto Statement with N `subject[]` entries. **No per-package L3 bundle.**
- **Why one L3 bundle for the build:** A single workflow run, against a single commit, by a single builder identity is one atomic build event. One bundle expresses that claim natively; N bundles fragment it into N redundant copies that share all the same metadata (commit SHA, builder identity, `workflow_ref`, timestamp). Sigstore-signing isn't free — N bundles means N OIDC handshakes against Fulcio, N short-lived certs, and N Rekor entries for a claim expressible once. The bundle JSON stays compact (~10 KB even at 100 subjects).
- **Two-layer attestation model (intentional).** Wrangle's L3 bundle is the *build* attestation. The adopter's publish loop separately produces the npm CLI's L2 in-CLI attestation via `npm publish --provenance` — one per package per publish, landing in each package's npmjs.org attestation slot. These map cleanly to different events at different granularities:
  - **L3 (wrangle, shared, build-time):** "these N artifacts are the build output of one run." One bundle, N subjects, one Sigstore signing.
  - **L2 (npm CLI, per-package, publish-time):** "this single tarball was published from this workflow." Per-package, per-publish.
  - Under changesets-style "only changed packages publish," the L2 attestations naturally cover only the released subset. The L3 bundle still enumerates all N built artifacts — that's accurate: wrangle *built* them, even if the adopter chose not to publish them all this release. The L3 attests build, not publish.
- **Filename:** Keep `npm-<shortname>.intoto.jsonl` (where shortname is the path-derived shortname of the workspaces root, e.g., `_` for `.`). Don't fan out filenames per package; the bundle's subjects array carries the per-package info.
- **Subject cap caveat.** The above assumes the SLSA generic generator accepts arbitrary-N subjects in one invocation. See "Open questions" — this is a pre-implementation verification item, since a hard cap below typical monorepo size would force a redesign.

### `slsa-verifier verify-artifact` semantics — verified

- **Confirmed behavior:** `slsa-verifier verify-artifact --provenance-path <bundle> --source-uri <repo> <artifacts...>` accepts multiple positional artifacts in one invocation and verifies each against the bundle's `subjects[].digest.sha256`. Failing any artifact fails the whole invocation.
- **Verify step shape:** Wrangle's verify step calls `slsa-verifier verify-artifact ... dist/*` **once** — not an N-call loop. This matches python's existing wheel+sdist verify pattern at `.github/workflows/build_and_publish_python.yml`. A loop would be N OIDC handshakes / Fulcio cert lookups for the same bundle with no behavioral benefit; one call is faster and matches the established cross-build-type pattern.

### SBOM scope — per-workspace-member, NOT repo-wide

- **Pick:** Run `syft dir:<member-path>` per workspace member, producing `metadata/npm/<shortname>/sbom-<member-shortname>.spdx.json` per member. `<shortname>` is the workspaces-root path-derived shortname (e.g., `_` for `.`); `<member-shortname>` is the per-member path-derived shortname (e.g., `packages_foo` for `packages/foo`) — **path-derived, not name-derived**, so the filename stays deterministic regardless of how the adopter scopes the published package name. Skip the repo-wide SBOM.
- **Why per-member:** An npm consumer installs one workspace package, not the whole repo. Per-package SBOM reflects what the consumer actually receives. Repo-wide SBOM (across the workspaces root + every member) double-counts shared transitive deps and includes dev tooling that doesn't end up in any published `.tgz`.
- **Alternative considered:** One repo-wide SBOM saves syft runs. Rejected — the false economy is paid by every downstream consumer who has to filter the SBOM to their package, and wrangle's per-build metadata layout already supports per-member directories.

### `workspace:` protocol resolution — must verify, not assume

- **Pick:** After pack, structurally verify that no resulting tarball contains a literal `workspace:` string in its embedded `package.json`'s `dependencies` / `devDependencies` / `peerDependencies`. The npm and pnpm pack commands resolve `workspace:*` / `workspace:^` / `workspace:~` specifiers to concrete versions automatically — but yarn berry's behavior is configurable, future pack-command changes could regress, and a third-party pack-like tool an adopter substitutes might not. The structural test is the guard.
- **Why mandatory, not "awkward case":** A tarball with `"foo": "workspace:*"` as a published dep breaks consumer installs (the consumer's package manager doesn't know what `workspace:*` means outside the workspaces context). Beyond the install break, the unresolved string is a supply-chain smell — the tarball wrangle attests doesn't match the dependency graph the consumer actually resolves. Catching this at build time keeps the L3 claim accurate.
- **Implementation:** `tar -xOf <tarball> package/package.json | jq -r '[..|strings] | map(select(startswith("workspace:"))) | length'` per tarball; fail if non-zero. Mandatory bats test in the implementation PR.

### Versioning coordination — wrangle stays agnostic

- **Pick:** Wrangle does NOT impose a versioning strategy. The example workflow shows both shapes via comments:
  - **Fixed versioning** (all packages share the same version, typical in Lerna's "fixed mode" and some changesets configurations): every `package.json` is updated together.
  - **Independent versioning** (each package has its own version, dominant in changesets default mode): per-package version files updated independently.
- **What wrangle DOES enforce:** every workspace member must have a `version` field at pack time. How that version gets there is the adopter's choice (changesets, manual bumps, prep-job equivalents to wrangle-test's `prep-python`).
- **Why not opinion:** Versioning policy is project-management, not supply-chain. Adopters who pick the wrong strategy notice immediately when packages don't install correctly; that signal lives outside wrangle.

### Scoped-package `--access public` handling — caller's example workflow

- **Pick:** The example workflow's publish loop calls `npm publish "$tgz" --provenance --access public --tag <tag>` per tarball. `--access public` is harmless on subsequent publishes of an already-public package, so adopters don't need to special-case "first publish of N." The npm CLI silently accepts the flag on existing packages.
- **One-time setup per package:** Adopters must bootstrap-publish v0.0.1 of *each* workspace member separately (per npm/cli#8544's first-publish constraint applying per-package). The bootstrap script can loop, but each individual `npm publish` is its own one-shot. Document in adopter onboarding.

### Failure semantics — atomic, no partial publish

- **Pick:** Any failure during pack, hash, provenance, or verify fails the entire workflow. The adopter's publish loop in the caller workflow should also fail atomically — if `npm publish` succeeds for packages 1-3 of 5 and fails for package 4, the workflow exits non-zero, and the adopter sees a partial-publish state on the registry that needs manual reconciliation.
- **Why atomic:** Partial-publish is recoverable, but partial-success-shown-as-success is not — adopters miss that some packages didn't ship. **Recovery mechanism (important to document accurately):** `npm publish` has no `--skip-existing` flag (that's PyPI). Re-publishing an already-published `<name>@<version>` returns HTTP 409. So the adopter's publish loop must gate each `npm publish` on the package version not already existing (e.g., `npm view <pkg>@<version>` returning empty) and skip on existence. changesets handles this automatically; a hand-rolled loop in the example workflow must include the gate. Wrangle's side of recovery — "what was built can be re-built byte-identical from the same commit + lockfile" — stays true; the npm-CLI mechanism for skipping the already-published subset is just different from PyPI's flag.
- **Best-effort alternative considered:** Continue past per-package publish failures, collect a summary. Rejected for v0.2 — adds complexity for a case better handled by re-running the workflow.

## Wrangle's value-add for workspaces

Same as the v0.1 npm pitch, multiplied across N packages:

- **Coordinated L3 provenance.** One bundle attests N artifacts produced from the same source at the same commit. Consumers verifying ANY package get the same supply-chain claim. No per-package signing ceremony for adopters to wire up.
- **Per-package SBOM** at a consistent layout (`metadata/npm/<shortname>/sbom-<member-shortname>.spdx.json`) — matches what consumers of any one workspace package actually need.
- **One workflow invocation** publishes N packages with consistent attestation. Adopters today have to wire this themselves; changesets/lerna handle the orchestration but don't ensure SLSA L3 across the set.
- **Tarball-direct publish** preserves the hash-pinned binding between what wrangle attests and what consumers download, the same as v0.1's single-package case.

## Awkward cases

- **Partial workspace publishes.** Adopters who only publish a subset of workspace members per release (e.g., changesets' "only changed packages publish" mode). Wrangle should pack ALL members but the adopter's publish loop is free to skip un-changed ones. This requires the example workflow to demonstrate a "is-this-package-in-the-changeset" gate per tarball — likely via `jq` against `.changeset/`'s state file or via changesets' own `changeset publish`. **Documented as adopter-side workflow concern, not wrangle's job.**
- **Mixed-scope packages in one repo.** Workspaces with `@org/foo` and `@org-other/bar` and bare `top-level`. Wrangle handles each per its own metadata; no special casing. The Trusted Publisher must be registered per-package on npmjs.com, which is an adopter-onboarding scaling concern (N registrations instead of 1).
- **Workspaces that DON'T publish** (private packages, examples, tests). `package.json` with `"private": true` is conventionally skipped by `npm pack --workspaces` and similar. Wrangle should respect this — don't pack `private: true` members, and don't include them in the expected-count check. Document explicitly so adopters who set `private: true` don't get confused by why a package "isn't in the bundle."
- **Native modules in one member of many.** Same SBOM scope limitation as v0.1 noted in the existing SPEC — `prebuild-install`-fetched binaries aren't in source. Per-member SBOM doesn't change this; adopters who need binary-level coverage still layer Trivy/Grype.
- **Changesets-aware workflows.** Most workspace-shaped npm repos use [changesets](https://github.com/changesets/changesets) for version + publish orchestration. The example workflow should show one explicit changesets pattern (probably using `changesets/action` for the version-bump step + wrangle for the build/publish). This is the most-likely-to-be-correct shape for v0.2 adopters; wrangle stays tool-agnostic but the canonical example reduces friction.

## Implementation notes

Things the implementation PR will need to handle. Not commitment, just reminders for the implementer.

- **`build_and_pack.sh` branching.** The single-package path stays as-is; the workspaces path is a separate code branch keyed on `jq 'has("workspaces")' package.json`. Don't try to unify — the assertions differ (single tarball vs. multi-tarball-count).
- **`action.yml` output shape.** New output `tarballs` (newline-separated list) added. The existing singular `tarball` is populated only on the single-package path; **on the workspaces path it stays empty**. Rationale: there are no v0.1 adopters with workspaces (validate_inputs.sh rejects them), so there's no breaking-change cost to forcing migration to `tarballs`. Populating `tarball` with "the first tarball" on the workspaces path would silently let single-package-shaped caller workflows under-publish 1 of N tarballs to the registry.
- **`tarball`-empty UX hint.** Empty output makes downstream `npm publish "$tarball"` fail with a relatively cryptic message. Surface the actionable migration hint two ways so adopters don't have to figure it out from npm's error alone:
  1. Emit a line to `$GITHUB_STEP_SUMMARY` from the build step when the workspaces path is active: *"Workspaces mode detected. The legacy `tarball` output is empty by design — consume the `tarballs` output (newline-separated list) instead. See README → Workspaces."* This shows up in the GitHub UI right above the failed downstream step.
  2. README migration section explicitly naming the empty-tarball-in-workspaces-mode contract.
  Sentinel-string approach (`tarball=ERROR_WORKSPACES_REQUIRE_TARBALLS_OUTPUT`) was rejected: it passes adopters' defensive `[[ -n "$tarball" ]]` checks, then proceeds with a broken value — worse than failing the check.
- **Optional additional signal.** If the job-summary line isn't sufficient in practice, an additive output `tarball-unavailable-reason: "workspaces mode — use the tarballs output"` could be added later. Doesn't interfere with `tarball`'s emptiness semantics. Leave out of v0.2 unless evidence warrants.
- **Hash computation step.** `cd "$INPUT_PATH/dist" && sha256sum -- $(ls -1 *.tgz | LC_ALL=C sort) | base64 -w0` — sort with forced C locale for determinism across CI runner locales. Same shape as the single-package case, just N entries instead of 1.
- **Metadata directory layout.** `metadata/npm/<shortname>/sbom-<member-shortname>.spdx.json` per member (member-shortname is path-derived per the SBOM section above). The unified-metadata convention from `docs/SPEC.md` already supports this — multiple files per metadata dir is allowed.
- **Verify step in reusable workflow.** Single `slsa-verifier verify-artifact ... dist/*` invocation (not an N-call loop). Mirrors python's existing wheel+sdist verify shape.
- **No new SHA-pinned actions needed.** Workspaces support reuses everything from v0.1 npm — `actions/setup-node`, `sigstore/cosign-installer`, `slsa-framework/slsa-verifier`, `actions/upload-artifact`, the same SLSA generic generator. The change is in `build_and_pack.sh` and `action.yml` only.
- **bats coverage:** structural tests for the new branch — "if workspaces field present, validate per-member name+version exists"; "hash step sorts before base64"; "verify step is one call, not a loop"; "private: true members are skipped"; "no tarball contains literal `workspace:` in its embedded package.json's deps." Mirror the existing test.bats patterns.

## Open questions for the implementation PR

- **Yarn Berry behavior.** Confirm `yarn workspaces foreach pack` produces tarballs with the same naming and writes to a deterministic location. Yarn ecosystem support is third in priority (#207 covers pnpm); could be deferred to a separate follow-up PR.
- **Versioning prep-step interaction.** Wrangle-test's `prep-python` and `prep-npm` bump version per-run for integration tests. For workspaces, the prep would need to bump per-member or coordinated. Whether wrangle ships an opinionated prep helper is an open question — leaning toward "no, document the changesets pattern instead."
- **SLSA generator subject cap — design-blocking, verify before implementation starts.** The generic generator's per-invocation subject cap, if any. Large workspace repos exist in the wild (Babel 100+, TanStack ~40 packages). The empirical check is cheap: throwaway workflow that invokes `generator_generic_slsa3.yml` with a synthetic 100-subject `base64-subjects` input and observes. As of slsa-github-generator v2.1.0 no hard cap is documented, but absence of documentation isn't confirmation. Treat as a prerequisite, not a follow-on. **If a cap is found**, two pre-thought redesign paths so the implementer doesn't have to invent under pressure:
  - **Chunked bundles** — emit `npm-<shortname>-<chunk>.intoto.jsonl` × `ceil(N/cap)`. Preserves a uniform verification flow ("verify each tarball against the bundle whose name encodes its chunk"); loses the single-bundle property. Adopters consume via a tarball→chunk-bundle mapping in the example workflow.
  - **Per-namespace bundles** — group by `@scope` or top-level workspace dir. More semantically cohesive (each bundle attests a coherent product surface); requires adopter understanding of the grouping rule. Better when scopes don't cross-depend.
  Either reshapes "Provenance bundle" above; neither is hard to implement, but the example-workflow shape and verify step's loop need to know which is in play. Prefer chunked if cohesion across scopes matters (TanStack-shaped); prefer per-namespace if scopes are independently consumable (Babel-shaped).
- **Single-package fallback during transition.** Adopters currently using v0.1 npm with no workspaces don't need to change anything when v0.2 ships — the workspaces-detection branch only activates when `workspaces` is in `package.json`. Verify this in a structural test.

## Out of scope

- **pnpm support itself** — tracked in [#207](https://github.com/TomHennen/wrangle/issues/207), lands first.
- **Yarn Berry support** — separate follow-up PR. Same shape as pnpm in principle, but Yarn's CLI differs enough to warrant its own validation pass.
- **changesets specifically** — wrangle stays tool-agnostic. The example workflow shows ONE changesets pattern as a starting point; alternatives (Lerna, Nx, manual prep) work without wrangle changes.
- **Auto-detecting partial publish state** to reconcile registry vs. local. That's changesets-territory (it gates each publish on `npm view <pkg>@<version>` — `npm publish` itself has no `--skip-existing` flag); wrangle just packs and signs.
- **Source-side workspaces semantics** (per-package OSV scanning, per-package Scorecard) — out of `build/actions/npm`'s scope; lives in `actions/scan` if it's worth doing at all.

## Related

- [#207](https://github.com/TomHennen/wrangle/issues/207) — pnpm-only support, single-package. Predecessor.
- [#205](https://github.com/TomHennen/wrangle/issues/205) — do NOT enable pnpm-store cache when pnpm/yarn support lands. Cross-cuts.
- [`build/actions/npm/SPEC.md`](./SPEC.md) — v0.1 npm SPEC, which this Phase 1 builds on.
- [SLSA generic generator README](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md) — multi-subject behavior reference.
- [changesets](https://github.com/changesets/changesets) — most-common workspace versioning tool.
