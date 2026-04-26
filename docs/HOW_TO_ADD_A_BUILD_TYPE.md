# How to Add a New Build Type

This is the runbook for wrangle contributors adding a new build type (npm, Go, GitHub Actions, generic, etc.). It captures lessons from the existing types — container, shell, python — so the next type doesn't rediscover them.

This doc focuses on **the wrangle contributor experience**: what files to write, in what order, what to watch out for. For per-ecosystem build conventions ("how do most python projects build today"), see [#99](https://github.com/TomHennen/wrangle/issues/99); the per-type research feeds back into Phase 1 below.

## Phase 1 — Ecosystem research

Before writing any code, document the community's standard practices for the ecosystem you're targeting. This research determines what wrangle should *do* for that build type. Capture answers in the build type's `SPEC.md` "Design principles" section as you write it.

Questions to answer:

- **Canonical build tool.** What does the community use? `docker buildx` for containers; `python -m build` (or `uv build`) for python; `npm pack` for npm; `go build` for Go. Pick one; document why.
- **Canonical SBOM tool.** Is there an in-build SBOM (BuildKit attestation, npm's `--provenance`)? An external generator (syft, cdxgen)? What output format does the ecosystem expect? Wrangle uses SPDX consistently — see "Decisions to inherit" below.
- **Canonical publish target.** Where do projects publish? GHCR, PyPI, npm registry, GitHub Releases, Maven Central, etc.
- **Canonical attestation pattern.** PEP 740 for python, OCI attestations for container, npm provenance, etc. Each ecosystem has its own; wrangle integrates with the ecosystem-native pattern *and* layers SLSA L3 provenance on top.
- **Authentication model.** Trusted publishing (PyPI, npm) is preferred over API tokens. Document what the adopter needs to configure on the registry side — see python's "Adopter onboarding" section as a template.
- **Reference workflow patterns.** Read 2–3 popular projects' GitHub Actions workflows for that ecosystem. Note what they have in common and what wrangle can absorb.

Outputs of this phase: a section in `build/actions/<type>/SPEC.md` titled "Design principles" that records every decision and why. Future contributors should be able to read it and understand the trade-offs without re-doing the research.

## Phase 2 — Structural template

Every build type has the same shape. Copy from `build/actions/python/` (or `container/`) as a starting point.

```
build/actions/<type>/
├── action.yml              # the composite action
├── SPEC.md                 # design spec (forward-looking; section: design principles, step sequence, security model)
├── README.md               # adopter how-to (currently-shipped behavior only)
├── test.bats               # structural tests
├── validate_inputs.sh      # input validation (delegates path checks to lib/validate_path.sh)
└── <other_helpers>.sh      # any other extracted run: blocks
.github/workflows/
└── build_and_publish_<type>.yml   # reusable workflow wrapping the composite + provenance job
gh_workflow_examples/
└── build_<type>.yml        # adopter-copyable example workflow
```

### Shared helpers — use, don't recreate

- **Path validation:** `lib/validate_path.sh` — every build type's `validate_inputs.sh` should delegate path checks here.
- **Download + verify:** `lib/download_verify.sh` — for any tool installer.
- **SHA-pin bump:** `make bump-action-pins` ([#165](https://github.com/TomHennen/wrangle/issues/165)) — run this whenever the composite action changes so the reusable workflow's `uses:` ref stays current.

### Inline `run:` blocks — extract from PR 1

CLAUDE.md's rule: any `run:` block that exceeds ~5 lines or contains logic (conditionals, loops) goes in a script under `build/actions/<type>/`. Don't write it inline first and refactor later — every existing build type that did the inline-first thing then had to refactor under PR review. Extract from PR 1.

### Top-level docs — update in the same PR

A new build type isn't done until these are also updated:

- `build/README.md` — add a section pointing to `build/actions/<type>/README.md` (existing convention: container has a section, python has a section).
- `gh_workflow_examples/README.md` — add a one-line entry for `build_<type>.yml`.
- `docs/SPEC.md`'s build-type table — mark the type as available in the version it ships in.

A bats test enforces this for python today (`python: README quick-start grants contents: write to build job` and similar). Model new build types' tests on the same pattern so docs can't silently drift.

## Phase 3 — Implementation order

Recommended commit sequence — each commit is testable on its own.

1. **SPEC.md skeleton.** Write the design principles, planned step sequence, planned outputs. Discussed with maintainers before writing code prevents scope creep.
2. **Composite action skeleton + helpers.** `action.yml` with input validation and a single "build" step that's a placeholder. Helper scripts (`validate_inputs.sh`, etc.) wired up. `test.bats` with structural assertions.
3. **Composite action implementation.** Real build/test/SBOM steps. Tests pass.
4. **Reusable workflow.** `build_and_publish_<type>.yml` wrapping the composite + a provenance job calling `slsa-github-generator`. Outputs (`metadata-artifact-name`, `dist-artifact-name` if applicable, `provenance-artifact-name`).
5. **Example workflow.** `gh_workflow_examples/build_<type>.yml` — adopter-copyable. The `build:` job's permissions MUST grant everything wrangle's reusable workflow's nested jobs declare. See "Common gotchas" below.
6. **Top-level doc updates** (`build/README.md`, `gh_workflow_examples/README.md`, `docs/SPEC.md`).
7. **README.md.** Adopter-facing how-to. Verify the example actually works end-to-end before merging.
8. **Integration fixture in `tomhennen/wrangle-test`.** See Phase 5.

Each commit should pass `./test.sh`. The integration test runs against the merged HEAD of wrangle, so adoption is exercised end-to-end before release.

## Phase 4 — Integration fixture

Every build type needs a fixture in the [tomhennen/wrangle-test](https://github.com/TomHennen/wrangle-test) companion repo. Without this, the integration test doesn't exercise the type, and bugs that only surface in real CI (permission cascades, output bindings, SLSA generator interactions) don't get caught.

Fixture template:

```
<type>/
├── <ecosystem-required-file>     # e.g., pyproject.toml, package.json, go.mod, Dockerfile
├── src/                          # minimal source
└── tests/                        # minimal tests (if applicable)
```

Then add a job to `.github/workflows/test-wrangle.yml.template`:

```yaml
test-<type>:
  permissions:
    # Match what wrangle's reusable workflow needs — see Common Gotchas below.
    contents: write   # if provenance has upload-assets or other write needs
    id-token: write   # for SLSA generator OIDC
    actions: read     # for SLSA generator env detection
  uses: TomHennen/wrangle/.github/workflows/build_and_publish_<type>.yml@__WRANGLE_SHA__
  with:
    path: <type>
```

If your build type has multiple variants worth exercising (e.g., python's pip vs uv paths), add a second fixture (`<type>-<variant>/`) and a parallel job. Both python's `python/` (pip) and `python-uv/` (uv) fixtures are exercised this way.

## Common gotchas (the retrospective)

Lessons from container/shell/python that the next build type should *expect* to hit:

### Permission cascade through nested reusable workflows

GitHub validates a called reusable workflow's job-level permissions at workflow startup, regardless of any `if:` condition that might skip the job. The caller (your example workflow's `build:` job; wrangle-test's `test-<type>:` job) must grant every scope every called job declares — even when those jobs would skip at runtime.

Specifically: if your reusable workflow's `provenance:` job uses `slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.1.0`, the caller must grant **`contents: write`** because that generator's `upload-assets` job declares `contents: write` even though it's gated by `if: inputs.upload-assets`.

The container generator (`generator_container_slsa3.yml`) is different — it declares `permissions: {}` at the workflow level and `packages: write` for upload, no `contents: write`. So container callers grant `packages: write` instead.

**What to do:** Read the SLSA generator workflow you're using, identify every permission its jobs declare, and grant the union in your reusable workflow's caller AND in the example workflow AND in the wrangle-test fixture's job. PR #156 hit this three times before getting it right.

### SLSA generator output names are not what you'd guess

`generator_generic_slsa3.yml@v2.1.0` outputs `provenance-name` (the artifact filename), not `provenance-download-name` or `provenance-artifact-name`. PR #156 spent a commit on this. Read the generator's `workflow_call.outputs` block in its actual source — don't infer names from documentation summaries.

### Inline `run:` blocks must be extracted from PR 1

CLAUDE.md's rule applies. The first PR that adds your build type should not have inline `run:` blocks longer than ~5 lines or containing logic. Every existing build type that started inline got refactored under review.

### Path validation belongs in `lib/validate_path.sh`

Don't reinvent. Both container and python now delegate. New build types do the same.

### The example workflow MUST be exercised end-to-end before merge

Don't trust grep-based bats tests for the example. PR #156 almost shipped an example workflow with the wrong permissions (would have failed at startup for every adopter on first run); the bug was caught only because reviewer asked about end-to-end testing. The wrangle-test integration test covers wrangle-test's template, not the example — so the example is its own verification surface.

Concrete check before merge: copy the example workflow into a scratch repo or compare it byte-for-byte with the wrangle-test fixture. If the permissions block differs from what wrangle-test grants, one of them is wrong.

### The composite-action SHA pin in the reusable workflow lags every commit

`build_and_publish_<type>.yml` references the composite action by SHA: `TomHennen/wrangle/build/actions/<type>@<sha>`. Every commit that changes the composite needs this pin bumped — otherwise the reusable workflow keeps pulling stale composite code.

**Use `make bump-action-pins`** ([#165](https://github.com/TomHennen/wrangle/issues/165)) on every PR that touches a composite. Idempotent, no-op if pins are already current.

### wrangle-test fixture coordination is a multi-PR dance

Permission or fixture-structure changes usually require:

1. A wrangle-test PR to add/update the fixture and template
2. A wrangle PR that depends on that PR being merged

Plan for the latency. PR #156 needed three wrangle-test PRs (fixture, permission grants, and the python-uv variant) interleaved with wrangle pushes.

## Decisions to inherit (cross-references)

These are wrangle-wide decisions a new build type should follow without rethinking:

- **Unified metadata layout** — every build type writes to `metadata/<type>/<shortname>/` and uploads as `<type>-metadata-<shortname>`. See [`docs/SPEC.md`](./SPEC.md) "Unified metadata layout" and [#150](https://github.com/TomHennen/wrangle/issues/150).
- **Provenance gating** — `if: ${{ ! startsWith(github.event_name, 'pull_') }}` is the default. Configurable per build via the `provenance-events` (or equivalent) input — see [#161](https://github.com/TomHennen/wrangle/issues/161).
- **Action SHA pinning** — full SHA refs for `TomHennen/wrangle/...` (forks pending [#137](https://github.com/TomHennen/wrangle/issues/137) / `$/` syntax [#136](https://github.com/TomHennen/wrangle/issues/136)). Use `make bump-action-pins`.
- **Test patterns** — start with structural bats tests for the YAML and helpers; add behavioral tests for any extracted scripts. The integration test in wrangle-test exercises end-to-end. See [#160](https://github.com/TomHennen/wrangle/issues/160) for the broader test-quality cleanup.
- **No `curl | sh`, no `/usr/local/bin`** — install scripts use `lib/download_verify.sh` and install to `$WRANGLE_BIN_DIR`. CLAUDE.md is the canonical source.
- **Permissions are minimal** — `permissions: write-all` is forbidden. Each job declares only what it needs. The reusable workflow declares only what its inner jobs need.

## Updating this runbook

When your build-type PR surfaces a new lesson — a permission gotcha, an output-name surprise, an integration-test footgun — update this runbook in the same PR. The runbook gets staler the further you get from the conversation; capturing the lesson immediately is the cheap part.

Conversely: if a section here is wrong or stale, fix it. Don't write around it.

## PR readiness checklist

Before requesting review on a new build-type PR, verify:

- [ ] `./test.sh` passes locally.
- [ ] `make bump-action-pins` was run; no stale SHA refs.
- [ ] `build/actions/<type>/{action.yml, SPEC.md, README.md, test.bats}` all exist.
- [ ] `.github/workflows/build_and_publish_<type>.yml` exists.
- [ ] `gh_workflow_examples/build_<type>.yml` exists; permissions match what wrangle-test grants for the same workflow.
- [ ] `build/README.md` has a section pointing at the new README.
- [ ] `gh_workflow_examples/README.md` has a one-line entry for the new example.
- [ ] `docs/SPEC.md`'s build-type table marks the new type as available.
- [ ] No inline `run:` blocks longer than ~5 lines or containing logic in `action.yml`.
- [ ] Path validation delegates to `lib/validate_path.sh`.
- [ ] Metadata is written to `metadata/<type>/<shortname>/` and uploaded as `<type>-metadata-<shortname>`.
- [ ] Reusable workflow exposes `metadata-artifact-name`, `provenance-artifact-name` (if SLSA-generated), and any type-specific outputs (e.g., `dist-artifact-name` for python).
- [ ] Integration fixture exists in `tomhennen/wrangle-test` and a `test-<type>:` job is in the template.
- [ ] If the integration test passes, the build type is ready for adopter use.
- [ ] If your PR surfaces a new lesson, this runbook was updated in the same commit.
