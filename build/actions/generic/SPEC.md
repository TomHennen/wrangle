# Wrangle Generic Build Type — Phase 1 Research

**Status:** Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md), re-interpreted for the case where wrangle has no ecosystem to lean on. This document recommends the defaults for an eventual `build/actions/generic/` implementation. No `action.yml` exists yet.

Contract-shape questions (how `build.sh` is invoked across CI systems, the type-args interface, etc.) belong to [#171](https://github.com/TomHennen/wrangle/issues/171) and are deliberately out of scope here.

## Overview

Generic is the build type for adopters whose project does not fit a recognized ecosystem (npm, container, python, Go, …). Instead of guessing the build tool, **wrangle invokes adopter-supplied shell scripts** checked into the adopter's repo (`build.sh`, optionally `test.sh`, `install-deps.sh`, `lint.sh`). Wrangle hashes the artifacts the build declares and hands those hashes to the SLSA generator.

**Operating model.** Wrangle owns the build hygiene (test, SBOM, vulnscan, lint enforcement, gating, metadata layout, hash-pinned handoff to the generator) and produces its own L3 SLSA provenance via `slsa-framework/slsa-github-generator`, stored in `metadata/generic/<shortname>/`. The L3 bundle is verifiable offline by any consumer. There is no ecosystem-native attestation slot to compete with for generic — wrangle's L3 is the attestation, by construction.

**Why this composes meaningfully for generic.** Wrangle's reusable workflow is what executes the adopter's scripts, and the SLSA L3 provenance the generator emits records *wrangle's* `workflow_ref`. That means wrangle's hygiene — refusing to run a script that isn't in the repo, validating script paths, blocking `curl … | sh`-shaped install patterns, requiring tests to pass before the build runs — is what the L3 envelope transitively certifies. "L3 attaches to the signing path, not to the build hygiene" is literally true upstream, but wrangle is the workflow in the signing path; the build hygiene wrangle adds *becomes* part of what the envelope attests.

The right way to read the contrast with a "wrap-only" shape (where wrangle would compute hashes and SBOM for an artifact built outside wrangle, then hand off to the generator) is **where build hygiene runs relative to the attested workflow context.** In the "wrangle invokes" shape, hashing, SBOM, vulnscan, and gating happen inside the workflow whose `workflow_ref` the provenance records and whose source commit is the calling repo — so the attestation transitively certifies that wrangle's hygiene ran against the same bits that were built. In a wrap-only shape, wrangle's hygiene runs alongside an externally-built artifact that came from somewhere unattested; even if wrangle's reusable workflow called the generator itself, the attested context would not include the build, only wrangle's post-hoc bookkeeping.

## Recommended defaults (the picks)

### Inputs — adopter-supplied scripts plus a small structured set

The adopter places scripts at conventional paths in their repo (proposal: `.wrangle/`, mirroring `.github/`). Wrangle invokes whichever exist, in a fixed order with separated failure semantics:

| Script | Required? | When wrangle runs it | Failure behavior |
|--------|-----------|----------------------|------------------|
| `install-deps.sh` | optional | First — toolchain / dependency setup | Failure stops the pipeline before tests |
| `test.sh` | optional, recommended | Before the build | Failure stops the pipeline; wrangle attests in metadata that tests were run |
| `build.sh` | **required** | After tests pass | Failure stops the pipeline; no provenance generated |
| `lint.sh` | optional | In parallel with or before build | Failure stops the pipeline (lint is a build-stage gate, same as test) |

Plus a small set of structured inputs:

| Input | Required? | Description |
|-------|-----------|-------------|
| `path` | no, default `.` | Project root; same semantics as python/container |
| `artifact-paths` | yes, non-empty | Workspace-relative file list. Each listed file must exist after `build.sh` exits zero. Wrangle hashes each and emits one SLSA subject per file. |
| `release-events` | no | Same vocabulary as every other build type. Default `non-pull-request`. |

`artifact-paths` is **a list of exact filenames**, not a glob. Globs are convenient but a footgun against `slsa-verifier verify-artifact` consumers, who match subjects against the downloaded artifact's filename — an empty-glob expansion silently emitting zero subjects, or a glob that picks up an unintended `.bak` file, both fail in subtle ways downstream. The simple-list form ships v0.1; glob support can be added later if real adopters hit it.

**Adopter shape (sketch).** What a caller workflow looks like in the picked shape:

```yaml
# .github/workflows/release.yml in the adopter's repo
jobs:
  build:
    permissions:
      contents: write    # for the SLSA generator's upload-assets cascade
      id-token: write
      actions: read
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_generic.yml@v0.x.y
    with:
      path: .
      artifact-paths: |
        dist/myproject-1.2.3.tar.gz
        dist/myproject-1.2.3.tar.gz.sig
      release-events: tag-only
```

```bash
# .wrangle/install-deps.sh in the adopter's repo
set -euo pipefail
sudo apt-get install -y build-essential cmake

# .wrangle/test.sh
set -euo pipefail
ctest --output-on-failure

# .wrangle/build.sh
set -euo pipefail
cmake -B build && cmake --build build
mkdir -p dist
tar -czf dist/myproject-1.2.3.tar.gz -C build/out .
```

The adopter writes ordinary shell, lints it with their own `shellcheck`, tests it locally. Wrangle invokes it.

### Why scripts and not a `command:` DSL

A `command:` string input invites the entire shell-vs-argv design conversation: how to escape, whether to evaluate through `bash -c`, how to attest the command in the provenance, whether to forward env vars, what happens with multi-line. None of those questions have a happy answer that fits in a single GitHub Actions input. Worse, a `command:` input is a fresh injection surface against wrangle's own action — every adopter-controlled string that flows into a `run:` step has to be funneled through `env:` and threaded carefully through validation.

Pushing the build into a script file delegates *all* of that complexity to the adopter's repo, where it belongs:

- The adopter can `shellcheck` their own `build.sh`, write integration tests for it, code-review changes to it, and pin its dependencies.
- Wrangle has one wire-format question — "does this script file exist at the declared path?" — instead of N escaping questions.
- The provenance gets something more meaningful than a command string: the script file is in the source tree, so the recorded source commit is sufficient to recover what built the artifact. Reviewers can `git show <commit>:.wrangle/build.sh` rather than parse a command field out of provenance metadata.

This sidesteps Tom's L40 question entirely: there is no DSL to design.

### Build tool

The adopter's `build.sh`. By definition there is no canonical pick — that is what "generic" means.

### SBOM

`syft` against the project workspace (`syft <path>`), output SPDX. Same tool wrangle's python build type uses, same install path (`tools/syft/install.sh`), same Cosign-keyless verification on the binary, same SPDX format wrangle uses everywhere.

`syft .` captures everything checked into the repo plus anything `install-deps.sh` and `build.sh` brought into the workspace. It will miss dependencies fetched into a build cache outside `$GITHUB_WORKSPACE` (Bazel, Gradle, ccache) — that's a real but acceptable limitation for v0.1; see "Awkward cases" below.

### Publish

**Caller-supplied; not in wrangle's reusable workflow.** Generic has no canonical registry, no canonical authentication model, and no canonical attestation format to attach. The adopter wires up their own publish job after wrangle's reusable workflow completes — `download-artifact` the dist, optionally `slsa-verifier verify-artifact` against the provenance, then push to wherever they push. Same shape as wrangle's python pattern (where publish has to live in the caller for OIDC reasons), and the same adopter ergonomic.

### Attestation

**SLSA L3 provenance via `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml`.** Wrangle's reusable workflow computes SHA-256 over each declared `artifact-paths` entry, base64-encodes them in the `<sha256> <name>` shape the generator expects, and hands them to the generator as `base64-subjects`. Same construction python and Pattern-B Go use; same L3 ceiling.

**L3 isolation, restated.** The generator runs in an isolated reusable workflow → that's where the L3 envelope is minted. Wrangle's reusable workflow is what invokes `build.sh` → wrangle's hygiene becomes part of what the envelope transitively certifies. (Addresses the L29 concern that the original draft was too dismissive of wrangle's role here.)

### Authentication

All caller-supplied. Generic has no ecosystem trusted-publishing story. The adopter's caller workflow handles whatever credentials their publish step needs; wrangle's reusable workflow does not forward `GITHUB_TOKEN`, secrets blocks, or `WRANGLE_EXTRA_*` vars into the user scripts unless a future input explicitly opts in. Provenance signing uses `id-token: write` via the SLSA generator — same as every other build type, no tokens.

### Linting

`lint.sh` is the recommendation. The adopter knows their linters; wrangle invokes if the script is present. Source-stage linting wrangle already provides applies independently — the source-scan workflow's `shellcheck` will lint the user's `.wrangle/*.sh` scripts the same as it lints any shell in the repo, with no new wiring.

### Stronger upstream alternative (mentioned, not picked)

The SLSA Docker builder ([`internal/builders/docker`](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/docker/README.md)) and the [BYOB framework](https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md) run the user's build inside a pinned builder image, in an isolated reusable workflow, and record the build command (or the wrapping container image digest) as an attested provenance field. That is a genuinely stronger story for opaque builds than `generator_generic_slsa3.yml` provides.

It is **not the v0.1 pick.** Adopting a different upstream interface for one build type would diverge generic's shape from python and container, complicate cross-build-type composability, and force adopters to learn a different surface for a single build type. Possible upgrade path if real adopters need attested-command provenance; out of scope here.

## Wrangle's value-add

An adopter could wire `generator_generic_slsa3.yml` directly without wrangle. The starter workflow at [`actions/starter-workflows`](https://github.com/actions/starter-workflows/blob/main/ci/generator-generic-ossf-slsa3-publish.yml) shows that path. Wrangle's generic build type adds, on top of that:

- **Test attestation.** `test.sh` is a separate input from `build.sh`, with separate failure semantics. When the workflow succeeds, the metadata records that tests ran — a downstream consumer reading wrangle's metadata directory sees that the build was tested, not just built. (Addresses Tom's L38: tests should not be bundled into the build command.) The starter workflow has no notion of tests.
- **SBOM and vulnerability scan.** `syft` over the workspace, `osv-scanner` over the SBOM. Both run for free; the starter has neither.
- **Hash-format correctness.** Wrangle owns the bare-filename hashing pattern that makes `slsa-verifier verify-artifact` work without each adopter rediscovering the `cd dist && sha256sum *` trick (see python SPEC step 5).
- **Automated artifact enumeration.** The adopter declares `artifact-paths` once. Wrangle wires that single declaration into both the artifact upload and the base64-subjects fed to the generator. Adding a new artifact is one edit, not two.
- **Permission-cascade handling.** Wrangle's reusable workflow declares the `actions: read | id-token: write | contents: write` union once; adopters' caller workflows don't have to know about `upload-assets`'s `contents: write` requirement to get past the validator on first run.
- **Release-events gating** via the shared `actions/release_gate` composite. Same vocabulary as every other build type.
- **Unified metadata layout.** `metadata/generic/<shortname>/sbom.spdx.json` + provenance + `summary.md` — one shape across every wrangle build type, so a multi-build caller workflow gets uniform downstream surfaces.
- **Build hygiene certified by the L3 envelope.** Because wrangle is what runs the scripts (in a reusable workflow whose `workflow_ref` is recorded by the generator), wrangle can refuse certain shapes — script files that don't exist in the repo at scan time, `artifact-paths` that escape the workspace, `install-deps.sh` that would pull a binary at runtime over an unverified channel — and that hygiene becomes transitively certified by the L3 envelope. An adopter wiring `generator_generic_slsa3.yml` directly gets the envelope without any of those guarantees baked in.

What wrangle's generic build type does **not** add (vs. python/container): no ecosystem-native attestation analogue (there isn't one), no toolchain auto-setup (the adopter writes `install-deps.sh`), no build-tool detection, no publish step. The candid framing: wrangle's value-add for generic is "everything around the build, packaged consistently with the rest of wrangle." That is real value, but thinner than what python or container adds — adopters comfortable wiring the SLSA generator directly will feel the gap less than a python adopter would.

**Caveat on the value-add list.** The "permission-cascade handling" and the multi-job split assume the upstream generator is `generator_generic_slsa3.yml`. If the "Stronger upstream alternative" pick later flips to the SLSA Docker builder, the permission shape changes (Docker builder uses BYOB's reusable-workflow framework with its own job topology); the value-add list and the step-sequence sketch would both need a refresh pass.

## Threat model

Generic's threat model is sharper than python's or container's because the build command is adopter-defined shell. Phase 1 calls out the surface without committing to validation mechanisms (Phase 2 / [#171](https://github.com/TomHennen/wrangle/issues/171) / [#183](https://github.com/TomHennen/wrangle/issues/183) pick those).

**In-scope (wrangle's job to make hard):**
- A poisoned `install-deps.sh` that fetches a tampered toolchain over an unverified channel — concretely, `curl http://… | sh` or `wget … && sh foo.sh` shapes. Generic is the build type most likely to attract these patterns precisely because there's no ecosystem package manager doing the lifting. The doc commits to "blocking `curl … | sh`-shaped install patterns" as part of the L3-envelope hygiene; the mechanism is open (source-stage shellcheck-with-custom-rule, an AST scan of `.wrangle/*.sh` before invocation, a runtime egress allowlist, or some combination — [#183](https://github.com/TomHennen/wrangle/issues/183) is the right place to commit).
- `artifact-paths` entries that escape the workspace via `..` or absolute paths (handled by `lib/validate_path.sh`, same as python).
- A `build.sh` that writes outside its expected output directory and that wrangle then unintentionally treats as an attested artifact (handled by the "exact list" `artifact-paths` shape — wrangle hashes only what is declared, so an unexpected write produces no subject).
- Adopter scripts attempting to read secrets out of the runner environment (handled by the same `WRANGLE_EXTRA_*` opt-in mechanism the tool adapters use — adopter scripts get a stripped env unless an input explicitly forwards a named var).

**Assumed-trusted (out of scope for wrangle to validate):**
- The *content* of `build.sh`, `test.sh`, and `lint.sh` themselves. These live in the adopter's repo, get source-stage shellcheck via the existing scan workflow, and are reviewed at the same gate as any other code change. Wrangle does not statically analyze the build's semantics — that's the adopter's job.
- The toolchain `install-deps.sh` installs once the install method itself passes wrangle's hygiene check. Generic cannot meaningfully validate "is this compiler trustworthy"; that's why it produces L3 provenance, not perfect security.

**Explicitly out of scope (until research lands):**
- Sandboxing adopter scripts (no namespace isolation, no egress control beyond what GHA itself offers).
- Reproducibility verification.
- Cross-language SBOM completeness when the build uses out-of-workspace caches (see Awkward cases).

The picks here let wrangle commit to "L3 + workspace SBOM + vulnscan + script-hygiene checks transitively certified by the L3 envelope." That is a substantial uplift over the starter workflow's L3-alone, and it is the boundary the doc draws deliberately.

## Step sequence (sketch)

The Go build type (PR [#238](https://github.com/TomHennen/wrangle/pull/238), merged 2026-05-24) split its composite action into **three composites with per-job permission scopes** rather than one composite under a single job — a real defense-in-depth concern: `go test` runs adopter test code and shouldn't hold `contents: write`. Generic should follow that shape, because `install-deps.sh`, `test.sh`, and `lint.sh` are all adopter-controlled shell scripts that wrangle invokes; running them in the same job as `build.sh` (which is followed by the upload-assets cascade that requires `contents: write`) defeats the same isolation.

Sketch — three composite actions under `build/actions/generic/`, executed by a reusable workflow `.github/workflows/build_and_publish_generic.yml`:

**Job: `checks` (`contents: read`)** — runs adopter quality-gate scripts that should not be able to write to the repo.
1. **Validate inputs.** `path` and each `artifact-paths` entry through `lib/validate_path.sh`. Confirm `build.sh` exists at `<path>/.wrangle/build.sh`. Note presence/absence of the optional scripts. Fast-fail on any validation error before running anything adopter-controlled.
2. **Run `install-deps.sh` (if present).** `bash -euo pipefail .wrangle/install-deps.sh`, working directory = `path`. Failure aborts.
3. **Run `lint.sh` (if present).** Same invocation shape. Failure aborts (v0.1 picks block; see Open questions).
4. **Run `test.sh` (if present).** Same shape. Failure aborts. On success, record in metadata that tests ran.

**Job: `release` (`contents: write`)** — runs the build itself and the artifact/hash pipeline. Depends on `checks` (skipped via `release_gate` for non-release events).
5. **Run `build.sh`.** Same invocation shape. Failure aborts. Adopter test scripts have already passed in the previous job; this job sees a clean workspace via `actions/checkout`.
6. **Validate declared outputs.** Each `artifact-paths` entry must exist as a regular file under `path` after `build.sh` exits zero. Missing file → abort with a diagnostic naming which path was missing.
7. **Compute SHA-256 hashes** over each declared artifact, in the bare-filename `<sha256> <name>` shape `slsa-github-generator`'s `base64-subjects` input expects. The hashing step `cd`s into the artifact's parent directory and uses bare filenames — same fix python carries (cf. python SPEC step 5).
8. **Generate SBOM.** `syft <path>` → SPDX JSON → `metadata/generic/<shortname>/sbom.spdx.json`.
9. **Upload artifacts.** `generic-dist-<shortname>` (the declared `artifact-paths`) and `generic-metadata-<shortname>` (the metadata directory).
10. **Write step summary.** Lists the build scripts that ran (presence of optional scripts), the declared artifacts and their hashes, and the metadata-artifact name.

**Job: `provenance` (`actions: read`, `id-token: write`, `contents: write`)** — calls `generator_generic_slsa3.yml@vX.Y.Z` with the computed `base64-subjects`. Tag-pinned, per [`#147`](https://github.com/TomHennen/wrangle/issues/147). Same shape every other build type uses.

**Job: `verify` (default token)** — downloads the published artifacts and provenance and runs `slsa-verifier verify-artifact` end-to-end inside the same workflow run, mirroring the verify-story Go shipped.

Likely composite layout:
```
build/actions/generic/
├── checks/action.yml     # validate + install-deps + lint + test
├── release/action.yml    # build + validate outputs + hash + SBOM + upload
└── verify/action.yml     # slsa-verifier
```
Phase 2 picks the exact split; this sketch reflects what Go actually shipped, not the pre-#238 single-composite assumption.

## Awkward cases

These are flagged for adopter-experience awareness; none block v0.1.

- **Multi-step builds.** Configure → compile → package → archive is the adopter's `build.sh` to structure. The script can use `set -euo pipefail` and call sub-scripts; wrangle does not need to model multi-step builds in inputs.
- **Build caches outside the workspace.** Bazel's `~/.cache/bazel`, Gradle's `~/.gradle/caches`, ccache, etc. live outside `$GITHUB_WORKSPACE`. Wrangle does not sandbox the user's scripts, so cache writes work; the SBOM (workspace scan) will not capture cache contents. Out of scope for v0.1; if cache-aware SBOM becomes important, that's a future input.
- **Multi-arch artifacts.** A build that produces `bin/amd64/foo`, `bin/arm64/foo`, `bin/darwin-arm64/foo` is one logical release with multiple files. The `artifact-paths` list handles this directly — list all three. The SLSA provenance carries N subjects under one attestation; `slsa-verifier verify-artifact` handles that natively.
- **Network access during the build.** Wrangle does not sandbox. If `build.sh` needs to fetch from a private mirror, that works; it inherits the runner's network.
- **Reproducibility.** Out of scope. Generic does not commit to reproducible builds; the SLSA generic generator does not require it. If the adopter's build is non-reproducible, the provenance still attaches — provenance proves *who built it*, not *that it can be rebuilt bit-for-bit*.
- **Empty-output case.** A "lint and test only" build with no artifact to release is the **shell** build type's job (`build/actions/shell/`). Generic's `artifact-paths` is required and non-empty; otherwise the two types overlap. Phase 2 should confirm the shell build type's current shape can absorb a "lint and test, no artifact" generic-shaped project, or pick a converged shape — the two types share enough surface (adopter shell scripts, no ecosystem) that the only contract difference today is whether an artifact is produced. If shell already absorbs the no-artifact case cleanly, that's the boundary; if it doesn't, the picks here should reconsider whether `artifact-paths` could be made optional and the two types merged.
- **Per-run-stamped filenames.** A build that writes `dist/myproject-2026-05-26-abc1234.tar.gz` (timestamp- or commit-hash-stamped) does not fit the static `artifact-paths` list shape — the adopter doesn't know the exact filename when they write the workflow. v0.1 picks list-not-glob (see Inputs section), which means the adopter either (a) wraps `build.sh` to rename the output to a stable name before exiting, or (b) waits for a future `artifact-paths-glob` input. Option (a) is the v0.1 answer; this case is a real forcing function for the glob-vs-list decision when it gets re-examined.
- **Builds that publish as part of the build itself.** A `build.sh` whose semantics include "push to a remote registry as part of producing the artifact" (where the artifact identity emerges only after a remote interaction — some container/OCI workflows do this) is **intentionally excluded** from generic. Generic's contract is "produce files locally, wrangle hashes them, wrangle hands hashes to the generator, an external publish job consumes the result." If the adopter needs publish-during-build semantics, that's what the per-ecosystem build types (container, the future Maven/OCI types) exist for.
- **Missing declared output.** A declared `artifact-path` that `build.sh` did not produce is unambiguously a build failure — no hash to compute, no subject to attest. Wrangle aborts. (The natural fit is exit-2 semantics, mirroring the tool-adapter contract's "tool error" exit code — see [`docs/SPEC.md`](../../../docs/SPEC.md) §Adapter Contract.)
- **Unexpected outputs.** Files that `build.sh` writes but the adopter did not declare in `artifact-paths` are simply not attested. Wrangle does not warn or fail; the contract is "you get provenance for what you declare."

## Implementation notes

These are forward-looking notes for the eventual implementer; expect refinement during Phase 2.

**Script invocation.** Wrangle invokes each script as `bash -euo pipefail .wrangle/<script>` from the project root (`path`). The shebang line in the script is irrelevant — wrangle picks the shell. This guarantees `set -euo pipefail` semantics regardless of what the adopter wrote inside the file.

**Working directory.** All scripts run with `cwd = path`. If the adopter needs a different working directory for a particular step, they `cd` inside their script.

**Required-vs-optional script handling.** `build.sh` is required: wrangle aborts validation before any step runs if the file is missing. The optional scripts (`install-deps.sh`, `test.sh`, `lint.sh`) are skipped if absent; their absence is logged but is not an error. Their presence-or-absence is recorded in the metadata so consumers can tell whether a given build was tested or linted.

**Where the scripts live.** Proposal: `.wrangle/` at the project root (or at `path` when `path != "."`). This mirrors `.github/` as a familiar convention, scopes wrangle-specific files into one directory, and makes the source-scan-workflow's shellcheck pickup automatic. To be confirmed in Phase 2; alternatives are top-level `wrangle.{build,test,…}.sh`, or a single `wrangle.yml` that points at script paths. Strong preference for the `.wrangle/` directory shape.

**Toolchain seam for portability.** `install-deps.sh` is the obvious place for an adopter to install language toolchains, since wrangle does not know what to install. It is also the obvious per-platform seam if and when wrangle gains non-GHA portability — the adopter can ship `install-deps.ubuntu.sh`, `install-deps.macos.sh`, etc., or a single script that branches on `$RUNNER_OS`. (This is what makes the scripts shape friendly to #171's eventual portability work, without committing to anything specific now.) `devcontainer.json` is a forward-looking richer shape — wrangle could in a future version offer to invoke the user's devcontainer for build steps — but that is not the v0.1 pick.

**Permissions.** Build job needs only `contents: read`. Provenance job needs `actions: read | id-token: write | contents: write` (for the generator's `upload-assets` cascade — see [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md) "Common gotchas"). Caller grants the same union.

**Input validation.** `path` and each entry of `artifact-paths` go through `lib/validate_path.sh` — same regex, same anti-traversal checks as python and container. The script-file existence check happens immediately after path validation; missing `build.sh` is a fast-fail.

## Open questions

- **`.wrangle/` directory location vs. alternatives.** Confirmed in Phase 2.
- **Whether wrangle should refuse to run a build if `test.sh` is absent in opt-in "strict" mode**, or whether absence is always silent-but-recorded. v0.1 picks silent-but-recorded; a future input could tighten this.
- **Lint failure as block-vs-warn.** v0.1 picks block (consistent with the build-stage failure contract). A `lint-mode: warn` input is a possible follow-up if adopters surface a need.
- **Devcontainer integration** as a richer toolchain shape. Forward-looking; not v0.1.
- **Mechanism for blocking `curl … | sh`-shaped install patterns.** The threat-model section commits to the goal; Phase 2 / [#183](https://github.com/TomHennen/wrangle/issues/183) picks the mechanism (source-stage shellcheck with a custom rule, an AST scan of `.wrangle/*.sh` before invocation, runtime egress allowlisting, or some combination).
- **Convergence with the shell build type.** Whether the existing `build/actions/shell/` shape can absorb a "lint and test, no artifact" generic-shaped project, or whether the two types should converge. See Awkward cases → empty-output case.
