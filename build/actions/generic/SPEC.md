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

The adopter places scripts at conventional paths in their repo. v0.1 proposal: `wrangle/` at the project root (no leading dot — see "Where the scripts live" below for why not `.wrangle/`). Wrangle invokes whichever exist, in a fixed order with separated failure semantics:

| Script | Required? | When wrangle runs it | Failure behavior |
|--------|-----------|----------------------|------------------|
| `install-deps.sh` | optional | First — toolchain / dependency setup | Failure stops the pipeline before tests |
| `test.sh` | optional, recommended | Before the build | Failure stops the pipeline; wrangle attests in metadata that tests were run |
| `build.sh` | **required** | After tests pass | Failure stops the pipeline; no provenance generated |
| `lint.sh` | optional | Sequentially inside `checks`, before `test.sh` | Failure stops the pipeline (lint is a build-stage gate, same as test). Note: this ordering means a lint failure prevents tests from running. Adopters wanting "run all gates and report all failures" can't get that from this shape today; the v0.1 trade-off favours fail-fast over parallel reporting. |

Plus a small set of structured inputs:

| Input | Required? | Description |
|-------|-----------|-------------|
| `path` | no, default `.` | Project root; same semantics as python/container |
| `artifact-paths` | yes, non-empty (see caveat) | Workspace-relative file list. Each listed file must exist after `build.sh` exits zero. Wrangle hashes each and emits one SLSA subject per file. |

**Caveat on the `yes, non-empty` contract.** This requirement is in tension with the "Empty-output case" in Awkward cases below: the shell build type is what owns the "lint and test, no artifact" shape today, and the only contract difference between generic and shell is whether an artifact is produced. If the Phase 2 convergence question (Awkward cases → empty-output case, tracked in #266) resolves toward generic absorbing shell, `artifact-paths` would have to become optional and a no-subject build path would have to be modelled (no SLSA generator call when the list is empty; metadata records "lint/test only"). The v0.1 implementer should treat `artifact-paths: required, non-empty` as a current pick, **not** as an immutable invariant — the validation layer, the reusable-workflow output shape, and the metadata schema should all be structured so that flipping this to optional is a one-spot change later, not a re-plumb.
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
# wrangle/install-deps.sh in the adopter's repo
set -euo pipefail
sudo apt-get install -y build-essential cmake

# wrangle/test.sh
set -euo pipefail
ctest --output-on-failure

# wrangle/build.sh
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
- The provenance gets something more meaningful than a command string: the script file is in the source tree, so the recorded source commit is sufficient to recover what built the artifact. Reviewers can `git show <commit>:wrangle/build.sh` rather than parse a command field out of provenance metadata.

This sidesteps the "why no `command:` DSL?" question entirely: there is no DSL to design.

### Build tool

The adopter's `build.sh`. By definition there is no canonical pick — that is what "generic" means.

### SBOM

`syft` against the project workspace (`syft <path>`), output SPDX. Same tool wrangle's python build type uses, same install path (`tools/syft/install.sh`), same Cosign-keyless verification on the binary, same SPDX format wrangle uses everywhere.

`syft .` captures everything checked into the repo plus anything `install-deps.sh` and `build.sh` brought into the workspace. It will miss dependencies fetched into a build cache outside `$GITHUB_WORKSPACE` (Bazel, Gradle, ccache) — that's a real but acceptable limitation for v0.1; see "Awkward cases" below.

### Publish

**Caller-supplied; not in wrangle's reusable workflow.** Generic has no canonical registry, no canonical authentication model, and no canonical attestation format to attach. The adopter wires up their own publish job after wrangle's reusable workflow completes — `download-artifact` the dist, optionally `slsa-verifier verify-artifact` against the provenance, then push to wherever they push. Same shape as wrangle's python pattern (where publish has to live in the caller for OIDC reasons), and the same adopter ergonomic.

### Attestation

**SLSA L3 provenance via `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml`.** Wrangle's reusable workflow computes SHA-256 over each declared `artifact-paths` entry, base64-encodes them in the `<sha256> <name>` shape the generator expects, and hands them to the generator as `base64-subjects`. Same construction python and Pattern-B Go use; same L3 ceiling.

**L3 isolation, restated.** The generator runs in an isolated reusable workflow → that's where the L3 envelope is minted. Wrangle's reusable workflow is what invokes `build.sh` → wrangle's hygiene becomes part of what the envelope transitively certifies. The "L3 attaches to the signing path, not to the build" framing is true upstream but understates wrangle's role: wrangle *is* the workflow in the signing path, so the hygiene wrangle layers in becomes part of what the signed envelope attests.

### Authentication

All caller-supplied. Generic has no ecosystem trusted-publishing story. The adopter's caller workflow handles whatever credentials their publish step needs; wrangle's reusable workflow does not forward `GITHUB_TOKEN`, secrets blocks, or `WRANGLE_EXTRA_*` vars into the user scripts unless a future input explicitly opts in. Provenance signing uses `id-token: write` via the SLSA generator — same as every other build type, no tokens.

### Linting

`lint.sh` is the recommendation. The adopter knows their linters; wrangle invokes if the script is present. Source-stage linting wrangle already provides applies independently — the source-scan workflow's `shellcheck` will lint the user's `wrangle/*.sh` scripts the same as it lints any shell in the repo, with no new wiring.

### Stronger upstream alternative (mentioned, not picked)

The SLSA Docker builder ([`internal/builders/docker`](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/docker/README.md)) and the [BYOB framework](https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md) run the user's build inside a pinned builder image, in an isolated reusable workflow, and record the build command (or the wrapping container image digest) as an attested provenance field. That is a genuinely stronger story for opaque builds than `generator_generic_slsa3.yml` provides.

For container-shaped builds specifically, the upstream `slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml` workflow is the container-image analogue of `generator_generic_slsa3.yml` and produces L3 provenance keyed to an OCI image digest rather than to file SHA-256 subjects — out of scope here (wrangle's container build type owns that surface), but noted as the right upstream target for an adopter whose "generic" build is really "produce a container image."

It is **not the v0.1 pick.** Adopting a different upstream interface for one build type would diverge generic's shape from python and container, complicate cross-build-type composability, and force adopters to learn a different surface for a single build type. Possible upgrade path if real adopters need attested-command provenance; out of scope here.

## Wrangle's value-add

An adopter could wire `generator_generic_slsa3.yml` directly without wrangle. The starter workflow at [`actions/starter-workflows`](https://github.com/actions/starter-workflows/blob/main/ci/generator-generic-ossf-slsa3-publish.yml) shows that path. Wrangle's generic build type adds, on top of that:

- **Test attestation.** `test.sh` is a separate input from `build.sh`, with separate failure semantics. When the workflow succeeds, the metadata records that tests ran — a downstream consumer reading wrangle's metadata directory sees that the build was tested, not just built. Tests are deliberately kept out of the build command itself so that "was this build tested?" is independently legible in the metadata rather than buried inside an opaque shell script. The starter workflow has no notion of tests.
- **SBOM and vulnerability scan.** `syft` over the workspace, `osv-scanner` over the SBOM. Both run for free; the starter has neither.
- **Hash-format correctness.** Wrangle owns the bare-filename hashing pattern that makes `slsa-verifier verify-artifact` work without each adopter rediscovering the `cd dist && sha256sum *` trick (see python SPEC step 5).
- **Automated artifact enumeration.** The adopter declares `artifact-paths` once. Wrangle wires that single declaration into both the artifact upload and the base64-subjects fed to the generator. Adding a new artifact is one edit, not two.
- **Permission-cascade handling.** Wrangle's reusable workflow declares the `actions: read | id-token: write | contents: write` union once; adopters' caller workflows don't have to know about `upload-assets`'s `contents: write` requirement to get past the validator on first run.
- **Release-events gating** via the shared `actions/release_gate` composite. Same vocabulary as every other build type.
- **Unified metadata layout.** `metadata/generic/<shortname>/sbom.spdx.json` + provenance + `summary.md` — one shape across every wrangle build type, so a multi-build caller workflow gets uniform downstream surfaces.
- **Build hygiene certified by the L3 envelope.** Because wrangle is what runs the scripts (in a reusable workflow whose `workflow_ref` is recorded by the generator), wrangle can refuse certain shapes — script files that don't exist in the repo at scan time, `artifact-paths` that escape the workspace, `install-deps.sh` that would pull a binary at runtime over an unverified channel — and that hygiene becomes transitively certified by the L3 envelope. An adopter wiring `generator_generic_slsa3.yml` directly gets the envelope without any of those guarantees baked in.

What wrangle's generic build type does **not** add (vs. python/container): no ecosystem-native attestation analogue (there isn't one), no toolchain auto-setup (the adopter writes `install-deps.sh`), no build-tool detection, no publish step. The candid framing: wrangle's value-add for generic is "everything around the build, packaged consistently with the rest of wrangle." That is real value, but thinner than what python or container adds — adopters comfortable wiring the SLSA generator directly will feel the gap less than a python adopter would.

**Upper boundary: cannibalization risk vs. typed build types.** The doc draws the lower boundary cleanly (shell handles the empty-artifact case; see Awkward cases). The upper boundary — when does generic eat into python, Go, container, or the future Maven/OCI types? — is fuzzier. An adopter with a python project that has unusual packaging (Bazel `py_binary`, non-PyPI distribution channel, custom `MANIFEST.in` that confuses `python -m build`) could plausibly reach for generic and still get L3 + SBOM + scan. They lose the PyPI trusted-publishing path and the ecosystem-native attestation slot — but for generic those weren't on offer anyway, so the framing here is *which build type is the adopter ergonomically locked into?*, not *which gives them more*. The differentiator is "wrangle picks the build tool for you" — and for adopters with unusual setups in a recognized ecosystem, that differentiator flips from feature to liability.

Phase 1 flags the question; Phase 2 picks the policy boundary. Candidates: (a) adopters in a recognized ecosystem are discouraged in docs/README from picking generic and nudged toward filing an issue against the typed build first; (b) `validate_inputs.sh` warns (not fails) if it detects `pyproject.toml` / `package.json` / `go.mod` and is being invoked as generic; (c) no policy — accept the cannibalization risk as the price of generic being usable at all. Filed for Phase 2 in #266.

**Caveat on the value-add list.** The "permission-cascade handling" and the multi-job split assume the upstream generator is `generator_generic_slsa3.yml`. If the "Stronger upstream alternative" pick later flips to the SLSA Docker builder, the permission shape changes (Docker builder uses BYOB's reusable-workflow framework with its own job topology); the value-add list and the step-sequence sketch would both need a refresh pass.

## Threat model

Generic's threat model is sharper than python's or container's because the build command is adopter-defined shell. Phase 1 calls out the surface without committing to validation mechanisms (Phase 2 / [#171](https://github.com/TomHennen/wrangle/issues/171) / [#183](https://github.com/TomHennen/wrangle/issues/183) pick those).

**In-scope (wrangle's job to make hard):**
- A poisoned `install-deps.sh` that fetches a tampered toolchain over an unverified channel — concretely, `curl http://… | sh` or `wget … && sh foo.sh` shapes. Generic is the build type most likely to attract these patterns precisely because there's no ecosystem package manager doing the lifting. The doc commits to "blocking `curl … | sh`-shaped install patterns" as part of wrangle's pre-build validation; the mechanism is open (source-stage shellcheck-with-custom-rule, an AST scan of `wrangle/*.sh` before invocation, a runtime egress allowlist, or some combination — [#183](https://github.com/TomHennen/wrangle/issues/183) is the right place to commit). The choice of mechanism determines whether the check is transitively in the L3 envelope or only reviewed at source-gate time — see "Honest caveat" at the end of this section.
- `artifact-paths` entries that escape the workspace via `..` or absolute paths (handled by `lib/validate_path.sh`, same as python).
- A `build.sh` that writes outside its expected output directory and that wrangle then unintentionally treats as an attested artifact (handled by the "exact list" `artifact-paths` shape — wrangle hashes only what is declared, so an unexpected write produces no subject).
- Adopter scripts attempting to read secrets out of the runner environment (handled by the same `WRANGLE_EXTRA_*` opt-in mechanism the tool adapters use — adopter scripts get a stripped env unless an input explicitly forwards a named var).

**Assumed-trusted (out of scope for wrangle to validate):**
- The *content* of `build.sh`, `test.sh`, and `lint.sh` themselves. These live in the adopter's repo, get source-stage shellcheck via the existing scan workflow, and are reviewed at the same gate as any other code change. Wrangle does not statically analyze the build's semantics — that's the adopter's job.
- The toolchain `install-deps.sh` installs once the install method itself passes wrangle's hygiene check. Generic cannot meaningfully validate "is this compiler trustworthy"; that's why it produces L3 provenance, not perfect security.
- The **verification tier** of whatever `install-deps.sh` uses to fetch packages, when it isn't `curl … | sh`-shaped. Wrangle's own tooling follows the CLAUDE.md hierarchy (canonical package manager with the strongest verification upstream supports — SLSA provenance > release attestation > Sigstore > hash-pinned package manager > raw SHA-256), but an adopter `install-deps.sh` that runs `pip install foo` without `--require-hashes`, `go install example.com/foo@latest` (unpinned), or `npm install bar` against a non-lockfile-pinned tree inherits the same supply-chain exposure wrangle avoids for its own tools. Opting into generic means owning this hygiene in the adopter's own script.

**Explicitly out of scope (until research lands):**
- Sandboxing adopter scripts (no namespace isolation, no egress control beyond what GHA itself offers).
- Reproducibility verification.
- Cross-language SBOM completeness when the build uses out-of-workspace caches (see Awkward cases).

The picks here let wrangle commit to "L3 + workspace SBOM + vulnscan + script-hygiene checks at the same review gate as the source." That is a substantial uplift over the starter workflow's L3-alone, and it is the boundary the doc draws deliberately.

**Honest caveat on "transitively certified by the L3 envelope."** Lines 12-14 and the value-add list ("Build hygiene certified by the L3 envelope") lean on the framing that wrangle's hygiene becomes part of what the SLSA envelope attests because wrangle's reusable workflow is what the generator records as `workflow_ref`. That is true **only for hygiene that runs inside the attested workflow context — i.e., inside the reusable workflow on the path between source checkout and provenance generation.** It is not automatically true for every mechanism that might land for `curl … | sh` blocking. Where each candidate mechanism sits:

- **Source-stage `shellcheck` with a custom rule** runs in the source-scan workflow, *before* the attested build workflow ever runs. It is reviewed at the same gate as the source (good), but is not transitively in the L3 envelope. The custom-rule infrastructure for this already exists as **wrangle-shell-lint** at `tools/wrangle-shell-lint/` (rules WSL001–WSL005) — `curl … | sh`-style detection would be a new WSL rule rather than greenfield tooling.
- **AST scan of `wrangle/*.sh` before invocation, inside the attested workflow** — yes, this is transitively in the envelope. The mechanism here is the same wrangle-shell-lint engine — running the AST scan inside the attested workflow (in addition to or instead of at source-gate time) is what moves it into the L3 envelope; the rule definitions can be shared between the two invocation points. With the multi-job topology picked above, the scan must run in **both** `checks` (before `install-deps.sh` first runs) and `release` (before `install-deps.sh` is re-run) to be load-bearing for the build job that produces the artifact. Single-job topologies would only need it once.
- **Runtime egress allowlisting** requires runner-level enforcement (e.g., a StepSecurity-style harness) that wrangle doesn't currently ship. Not in the envelope today.

The pragmatic framing wrangle should adopt until [#183](https://github.com/TomHennen/wrangle/issues/183) picks a mechanism: **"wrangle's script-hygiene checks run at the same review gate as the source they validate, and — where the chosen mechanism runs inside the reusable workflow — additionally inherit the L3 envelope's transitive attestation."** That is honest about the conditional nature without giving up the strong-form claim if the AST-scan mechanism wins. The current "L3 envelope certifies the hygiene" phrasing in the Operating model and value-add sections should be read with this caveat until the mechanism is picked.

## Step sequence (sketch)

The Go build type at `build/actions/go/` splits its composite action into **multiple jobs with per-job permission scopes** rather than one composite under a single job — a real defense-in-depth concern: `go test` runs adopter test code and shouldn't hold `contents: write`. Generic should follow that shape, because `install-deps.sh`, `test.sh`, and `lint.sh` are all adopter-controlled shell scripts that wrangle invokes; running them in the same job as `build.sh` (which is followed by the upload-assets cascade that requires `contents: write`) defeats the same isolation.

Sketch — a reusable workflow `.github/workflows/build_and_publish_generic.yml` composed of **six jobs**, mirroring the topology Go shipped (`guard` → `gate` → `checks` → `release` → `provenance` → `verify`). Both `guard` and `gate` are their own jobs because `permissions: {}` cannot be set on a composite step — only on a job.

**Topology-duplication flag and sequencing pick.** The six-job topology (`guard` → `gate` → `checks` → `release` → `provenance` → `verify`) is now present in `build_and_publish_go.yml`, and the python and npm reusable workflows carry a near-identical shape modulo per-build-type composite swaps. With generic, that becomes a fourth copy — the CLAUDE.md "no copy-paste across workflows: if the same step sequence appears in more than two workflow files, extract to a composite" rule is squarely triggered. The leading extraction candidate is a parameterized reusable workflow (or a "topology" composite) that owns the six-job skeleton and per-job permissions, with each build type plugging in its own `checks`/`release`/`verify` composites; filed under #266.

**Sequencing pick: ship generic as the fourth copy, then extract the topology in Phase 2 as immediate follow-on work** — not "extract first, then build generic on the shared skeleton." Rationale: four concrete build types are better inputs to the abstraction than three, the extraction is its own substantial design exercise that shouldn't block adopter-visible generic progress, and `tools/wrangle-shell-lint/` plus the integration suite already mean drift between the four copies is detectable. The trade-off, named explicitly so future readers see it: this accepts one round of four-way copy-paste living in `main`, which must be paid down promptly in Phase 2 or the extraction gets steadily harder as the four copies diverge.

**Job: `guard` (`permissions: {}`)** — preflight guard. Refuses to run under any trigger that lets attacker-controlled commits execute with the caller's secrets (`pull_request_target`, `workflow_run` from a forked PR). Must stay first under `jobs:`. This matters more for generic than for Go: generic is the build type most likely to attract `pull_request_target` / `workflow_run` invocation footguns precisely because adopters reach for it when their flow doesn't fit a canonical shape and try triggers they shouldn't. Reuses the existing `actions/preflight_guard` composite. Omitting this would make v0.1 a coin-flip on whether the implementer adds it.

**Job: `gate` (`permissions: {}`, `needs: [guard]`)** — release gate. Computes `should-release` based on the `release-events` input vs. the current event. Exposes `should-release` as a job output that every downstream job's `if:` consumes (`if: needs.gate.outputs.should-release == 'true'`). Reuses the existing `actions/release_gate` composite. This is a separate job — not a step folded into `checks` — for the same `permissions: {}` reason as `guard`.

**Job: `checks` (`contents: read`, `needs: [guard]`)** — runs adopter quality-gate scripts that should not be able to write to the repo. Runs unconditionally (not gated on `should-release`) so PRs still get lint/test signal.
1. **Validate inputs.** `path` and each `artifact-paths` entry through `lib/validate_path.sh`. Confirm `build.sh` exists at `<path>/wrangle/build.sh`. Note presence/absence of the optional scripts. Fast-fail on any validation error before running anything adopter-controlled.
2. **Run `install-deps.sh` (if present).** `bash -euo pipefail wrangle/install-deps.sh`, working directory = `path`. Failure aborts.
3. **Run `lint.sh` (if present).** Same invocation shape. Failure aborts (v0.1 picks block; see Open questions).
4. **Run `test.sh` (if present).** Same shape. Failure aborts. On success, record in metadata that tests ran.

**Job: `release` (`contents: write`, `needs: [gate, checks]`, `if: needs.gate.outputs.should-release == 'true'`)** — runs the build itself and the artifact/hash pipeline.
5. **Re-run `install-deps.sh` (if present).** Because `checks` and `release` run on **separate `ubuntu-latest` runners with separate `actions/checkout` steps**, the toolchain `install-deps.sh` populated in `checks` is not visible here. Generic must re-run `install-deps.sh` in `release`, just as Go re-runs `setup-go` in both jobs. This doubles install-deps execution time; acceptable v0.1 trade-off vs. the alternatives (cache the install output between jobs — pulls in #226's release-vs-PR cache asymmetry; collapse to single-job — defeats the permission isolation that's the entire reason for the split; containerize via `jobs.<id>.container` — convergence with the Docker-builder alternative the doc rejected). Phase 2 may revisit if real adopters surface install-time pain.
6. **Run `build.sh`.** Same invocation shape. Failure aborts. Adopter test scripts have already passed in `checks`; `release` sees a clean workspace via `actions/checkout`.
7. **Validate declared outputs.** Each `artifact-paths` entry must exist as a regular file under `path` after `build.sh` exits zero. Missing file → abort with a diagnostic naming which path was missing.
8. **Compute SHA-256 hashes** over each declared artifact, in the bare-filename `<sha256> <name>` shape `slsa-github-generator`'s `base64-subjects` input expects. The hashing step `cd`s into the artifact's parent directory and uses bare filenames — same fix python carries (cf. python SPEC step 5).
9. **Generate SBOM.** `syft <path>` → SPDX JSON → `metadata/generic/<shortname>/sbom.spdx.json`.
10. **Upload artifacts.** `generic-dist-<shortname>` (the declared `artifact-paths`) and `generic-metadata-<shortname>` (the metadata directory).
11. **Write step summary.** Lists the build scripts that ran (presence of optional scripts), the declared artifacts and their hashes, and the metadata-artifact name.

**Job: `provenance` (`actions: read`, `id-token: write`, `contents: write`, `needs: [gate, release]`, `if: needs.gate.outputs.should-release == 'true'`)** — calls `generator_generic_slsa3.yml@vX.Y.Z` with the computed `base64-subjects`. Tag-pinned, per [`#147`](https://github.com/TomHennen/wrangle/issues/147). Same shape every other build type uses.

**Job: `verify` (default token, `needs: [gate, provenance]`, `if: needs.gate.outputs.should-release == 'true'`)** — downloads the published artifacts and provenance and runs `slsa-verifier verify-artifact` end-to-end inside the same workflow run, mirroring the verify-story Go shipped.

**Self-hosted-runner caveat.** Generic's `install-deps.sh` is the only adopter-controlled script likely to require `sudo` (typed build types use `setup-*` actions that don't need it). On a self-hosted runner without sudo, the example `sudo apt-get install -y build-essential cmake` aborts at step 2. v0.1 does not pre-validate this — the failure mode is a runtime abort with a clear shell diagnostic. Phase 2 (#266) decides whether wrangle should warn at validate time or document this in the adopter-facing readme.

Likely composite layout:
```
build/actions/generic/
├── checks/action.yml     # validate + install-deps + lint + test
├── release/action.yml    # install-deps (re-run) + build + validate outputs + hash + SBOM + upload
└── verify/action.yml     # slsa-verifier
```
(`guard` and `gate` reuse existing composites under `actions/`, not generic-specific ones.) Phase 2 picks the exact split; this sketch reflects the multi-job split the Go build type at `build/actions/go/` actually shipped, not the single-composite shape earlier drafts assumed.

### Reusable workflow outputs

The reusable workflow exposes the **same output surface as `build_and_publish_go.yml`**, so a multi-build caller workflow gets a uniform downstream contract. This matters because [`docs/SPEC.md`](../../../docs/SPEC.md) §Unified metadata layout explicitly requires `provenance-artifact-name` so callers don't have to reconstruct the filename convention.

| Output | Source job | Description |
|--------|------------|-------------|
| `hashes` | `release` | Base64-encoded SHA-256 hashes of built artifacts (for SLSA provenance) |
| `version` | `release` | Release version, or `snapshot` for non-tag builds (derived from the event/tag; semantics TBD in Phase 2 since generic has no version-from-toolchain hook like goreleaser) |
| `dist-artifact-name` | `release` | Name of the uploaded dist artifact (`generic-dist-<shortname>`) |
| `provenance-artifact-name` | `provenance` | Name of the SLSA provenance workflow artifact. Empty when `should-release` is false. |
| `metadata-artifact-name` | `release` | Name of the workflow artifact containing `sbom.spdx.json`. Format: `generic-metadata-<shortname>`. |
| `checks-metadata-artifact-name` | `checks` | Name of the workflow artifact containing test/lint metadata, if any. Format: `generic-checks-metadata-<shortname>`. |
| `should-release` | `gate` | `"true"` if the event matches `release-events`; `"false"` otherwise. |

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

**Script invocation.** Wrangle invokes each script as `bash -euo pipefail wrangle/<script>` from the project root (`path`). The shebang line in the script is irrelevant — wrangle picks the shell. This guarantees `set -euo pipefail` semantics regardless of what the adopter wrote inside the file.

**Working directory.** All scripts run with `cwd = path`. If the adopter needs a different working directory for a particular step, they `cd` inside their script.

**Required-vs-optional script handling.** `build.sh` is required: wrangle aborts validation before any step runs if the file is missing. The optional scripts (`install-deps.sh`, `test.sh`, `lint.sh`) are skipped if absent; their absence is logged but is not an error. Their presence-or-absence is recorded in the metadata so consumers can tell whether a given build was tested or linted.

**Where the scripts live.** v0.1 proposal: **`wrangle/` (no leading dot) at the project root** (or at `path` when `path != "."`). This is a deliberate departure from the `.wrangle/` shape sketched in early drafts, because **`.wrangle/` is already wrangle's runtime metadata directory and is `.gitignore`d** by the gitignore stanza wrangle ships ([`docs/SPEC.md`](../../../docs/SPEC.md) §Metadata Directory: *"The `.wrangle/` directory is in `.gitignore` to prevent accidental commits"*). If an adopter committed `.wrangle/build.sh`, the default ignore would silently drop it, and the workflow would fail with "build.sh not found" on the runner's clean checkout.

Picking `wrangle/` (no dot) avoids the collision without overloading another conventional path. It is source-controlled by default (no leading dot, not gitignored), mirrors wrangle's existing `tools/` convention for repo-root visible source, and is unambiguous at a glance for a code reviewer who sees an adopter repo for the first time.

Alternatives considered and rejected for v0.1: (a) top-level `wrangle.{build,test,…}.sh` files — clutters the repo root and is awkward when scripts grow to need helper files; (b) keeping `.wrangle/` and re-scoping wrangle's runtime metadata path to `.wrangle/runtime/` or to `$RUNNER_TEMP` exclusively — a multi-build-type refactor that deserves its own design pass and shouldn't ride on generic's Phase 1; (c) a single `wrangle.yml` pointing at script paths — adds a config-format design conversation generic was specifically structured to avoid.

Phase 2 confirms the final directory shape against #266; the rest of this doc assumes `wrangle/`.

**Toolchain seam for portability.** `install-deps.sh` is the obvious place for an adopter to install language toolchains, since wrangle does not know what to install. It is also the obvious per-platform seam if and when wrangle gains non-GHA portability — the adopter can ship `install-deps.ubuntu.sh`, `install-deps.macos.sh`, etc., or a single script that branches on `$RUNNER_OS`. (This is what makes the scripts shape friendly to #171's eventual portability work, without committing to anything specific now.) `devcontainer.json` is a forward-looking richer shape — wrangle could in a future version offer to invoke the user's devcontainer for build steps — but that is not the v0.1 pick.

**Permissions.** Build job needs only `contents: read`. Provenance job needs `actions: read | id-token: write | contents: write` (for the generator's `upload-assets` cascade — see [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md) "Common gotchas"). Caller grants the same union.

**Input validation.** `path` and each entry of `artifact-paths` go through `lib/validate_path.sh` — same regex, same anti-traversal checks as python and container. The script-file existence check happens immediately after path validation; missing `build.sh` is a fast-fail.

## Open questions

All Phase 2 follow-ups from this doc are tracked in **[#266](https://github.com/TomHennen/wrangle/issues/266)** as a single tracking issue — research-doc follow-ups need their own issue refs or they rot inside the doc that flagged them. The `curl … | sh` blocking mechanism is tracked separately at **[#183](https://github.com/TomHennen/wrangle/issues/183)** since it predates this research and has its own scope.

Summary, with the v0.1 pick where one was made:

- **Adopter-script directory location** ([#266](https://github.com/TomHennen/wrangle/issues/266)). v0.1 pick: `wrangle/` (no leading dot — see Implementation notes for why not `.wrangle/`). Phase 2 confirms.
- **Strict-mode `test.sh` requirement** ([#266](https://github.com/TomHennen/wrangle/issues/266)). Whether wrangle should refuse to build if `test.sh` is absent in opt-in "strict" mode. v0.1: silent-but-recorded. May fold into [#194](https://github.com/TomHennen/wrangle/issues/194) (build-type lint placement).
- **Lint failure block-vs-warn** ([#266](https://github.com/TomHennen/wrangle/issues/266)). v0.1: block. A `lint-mode: warn` input is a possible follow-up.
- **Devcontainer integration** ([#266](https://github.com/TomHennen/wrangle/issues/266)) as a richer toolchain shape than `install-deps.sh`. Forward-looking; not v0.1.
- **Mechanism for blocking `curl … | sh`-shaped install patterns** ([#183](https://github.com/TomHennen/wrangle/issues/183)). Threat-model commits to the goal; #183 picks the mechanism. See "Honest caveat" in the threat-model section for the L3-envelope implications of each candidate.
- **Convergence with the shell build type** ([#266](https://github.com/TomHennen/wrangle/issues/266)). Whether `build/actions/shell/` absorbs the "lint and test, no artifact" case or whether the two types converge. See Awkward cases → empty-output case.
- **Cannibalization-policy boundary vs. typed build types** ([#266](https://github.com/TomHennen/wrangle/issues/266)). Whether to discourage adopters in a recognized ecosystem from picking generic. See "Upper boundary" under Wrangle's value-add.
- **`install-deps.sh` portability for self-hosted runners without sudo** ([#266](https://github.com/TomHennen/wrangle/issues/266)). v0.1: runtime abort with a clear shell diagnostic; no pre-validation. Phase 2 decides whether wrangle warns or documents.
