# How to Add a New Build Type

This is the runbook for wrangle contributors adding a new build type (npm, Go, GitHub Actions, generic, etc.). It captures lessons from the existing types — container, shell, python — so the next type doesn't rediscover them.

This doc focuses on **the wrangle contributor experience**: what files to write, in what order, what to watch out for. For per-ecosystem build conventions ("how do most python projects build today"), see [#99](https://github.com/TomHennen/wrangle/issues/99); the per-type research feeds Phase 1.

## Phase 1 — Ecosystem research

Before writing any code, document the community's standard practices for the ecosystem you're targeting. This research determines what wrangle should *do* for that build type. Capture answers in the build type's `SPEC.md` "Design principles" section as you write it.

Questions to answer:

- **Canonical build tool(s).** What does the community use? Sometimes one is enough (`docker buildx` for containers); sometimes multiple are first-class (python supports both `python -m build` for the standard PEP 517 path and `uv build` for the uv path; the action picks based on `uv.lock` presence). When multiple tools are first-class, document the detection rule and ship a fixture for each variant. When one is dominant, document why you chose it. Some types fit awkwardly — e.g., a lot of Go projects skip a binary build entirely and let consumers `go install` from a tag, so "build tool" may not be the right framing for that type at all; that's worth surfacing in Phase 1 research before committing to the full template.
- **Canonical SBOM tool.** Is there an in-build SBOM (BuildKit attestation, npm's `--provenance`)? An external generator (syft, cdxgen)? What output format does the ecosystem expect? Wrangle uses SPDX consistently — see "Decisions to inherit" below.
- **Canonical publish target.** Where do projects publish? GHCR, PyPI, npm registry, GitHub Releases, Maven Central, etc.
- **Canonical attestation pattern.** PEP 740 for python, OCI attestations for container, npm provenance, etc. Each ecosystem has its own; wrangle integrates with the ecosystem-native pattern *and* layers SLSA L3 provenance on top.
- **Authentication model.** Trusted publishing (PyPI, npm) is preferred over API tokens. Document what the adopter needs to configure on the registry side — see python's "Adopter onboarding" section as a template.
- **Reference workflow patterns.** Read 2–3 popular projects' GitHub Actions workflows for that ecosystem. Note what they have in common and what wrangle can absorb.

Outputs of this phase: a section in `build/actions/<type>/SPEC.md` titled "Design principles" that records every decision and why. Future contributors should be able to read it and understand the trade-offs without re-doing the research.

## Phase 2 — Structural template

Two flavors of build type, with different shapes:

- **Artifact-producing types** (container, python, npm, …) — produce something publishable, with SBOM, provenance, signing. Full template applies.
- **Validation-only types** (shell — wrangle's own dogfooding) — run linters and tests, no artifact, no provenance. Reduced surface; details below.

(Go is intentionally absent from the artifact-producing list. Many Go projects don't build a binary at all in CI — they tag a release and let consumers run `go install <repo>@<tag>`. Whether Go fits the artifact-producing template, the validation-only template, or warrants a dedicated "tag-and-attest" shape is a Phase 1 question for whoever picks up #116.)

Copy from `build/actions/python/` for an artifact-producing type, `build/actions/shell/` for a validation-only type.

### Artifact-producing types

```
build/actions/<type>/
├── action.yml              # the composite action
├── SPEC.md                 # design spec (forward-looking: design principles, step sequence, security model)
├── README.md               # adopter how-to (currently-shipped behavior only)
├── test.bats               # structural tests
├── validate_inputs.sh      # input validation (delegates path checks to lib/validate_path.sh)
└── <other_helpers>.sh      # any other extracted run: blocks
.github/workflows/
└── build_and_publish_<type>.yml   # reusable workflow: composite + provenance + (optional) publish helper
gh_workflow_examples/
└── build_<type>.yml        # adopter-copyable example workflow
```

### Validation-only types

```
build/actions/<type>/
├── action.yml              # composite action that runs the validators
└── test.bats               # structural tests
.github/workflows/
└── build_<type>.yml        # reusable workflow (no _and_publish — nothing to publish)
gh_workflow_examples/
└── build_<type>.yml        # adopter-copyable example
```

Validation-only types may grow `SPEC.md` and `README.md` as their scope expands. Shell ships without them today — that's a gap (#51 / #99) more than a deliberate exception. New validation-only types should add `SPEC.md` and `README.md` from PR 1; reduced scope is not a license to skip them.

### Naming conventions for `.github/workflows/` and `gh_workflow_examples/`

- **Reusable workflow at `.github/workflows/build_and_publish_<type>.yml`** if the type produces a publishable artifact; **`build_<type>.yml`** for validation-only.
- **Example at `gh_workflow_examples/build_<type>.yml`** — singular `<type>`, matching the build action directory name. (Container ships as `build_and_publish_containers.yml` (plural) — that's a pre-existing typo to fix in a follow-up; do NOT use the plural form for new types.)

### Shared helpers — use, don't recreate

- **Path validation:** `lib/validate_path.sh` — every build type's `validate_inputs.sh` should delegate path checks here. (Don't write inline `run:` blocks for path validation — see "Common gotchas.")
- **Download + verify:** `lib/download_verify.sh` — for any tool installer.
- **SHA-pin bump:** `make bump-action-pins` (PR #166 / issue #165, in flight) — run this whenever the composite action changes so the reusable workflow's `uses:` ref stays current. Until that lands, bump pins manually in the same commit as the composite change.

### Top-level docs — update in the same PR

A new build type isn't done until these are also updated:

- `build/README.md` — add a section pointing to `build/actions/<type>/README.md` (existing convention: container has a section, python has a section).
- `gh_workflow_examples/README.md` — add a one-line entry for `build_<type>.yml`.
- `docs/SPEC.md`'s build-type table (under "Build type extensibility") — mark the type as available in the version it ships in.

A bats test enforces this for python today (`python: README quick-start grants contents: write to build job` and similar). Model new build types' tests on the same pattern so docs can't silently drift.

## Phase 3 — Implementation order

Recommended commit sequence — each commit is testable on its own.

1. **SPEC.md skeleton.** Write the design principles, planned step sequence, planned outputs. Discussing this with maintainers before writing code prevents scope creep.
2. **Composite action skeleton + helpers.** `action.yml` with input validation and a single "build" step that's a placeholder. Helper scripts (`validate_inputs.sh`, etc.) wired up. `test.bats` with structural assertions.
3. **Composite action implementation.** Real build/test/SBOM steps. Tests pass.
4. **Reusable workflow.** `build_and_publish_<type>.yml` wrapping the composite + an `attest:` job that runs `actions/attest-build-provenance` (use `subject-path: dist/*` for a flat dist like npm/python, or `subject-checksums: dist/checksums.txt` for a goreleaser-style dist like go) and uploads the signed Sigstore bundle as a workflow artifact + a `vsa:` job that verifies that bundle against the per-eco `wrangle-provenance-<type>-v1` PolicySet (fail-closed) and emits the signed VSA. Outputs (`metadata-artifact-name`, `dist-artifact-name` if applicable, `provenance-artifact-name`).
5. **Example workflow.** `gh_workflow_examples/build_<type>.yml` — adopter-copyable. The `build:` job's permissions MUST grant everything wrangle's reusable workflow's nested jobs declare. See "Common gotchas" below.
6. **Top-level doc updates** (`build/README.md`, `gh_workflow_examples/README.md`, `docs/SPEC.md`).
7. **README.md.** Adopter-facing how-to. Verify the example actually works end-to-end before merging.
8. **Integration fixture in `tomhennen/wrangle-test`.** See Phase 5.

Each commit should pass `./test.sh`. The integration test runs against the merged HEAD of wrangle, so adoption is exercised end-to-end before release.

## Phase 4 — Integration fixture

Every build type needs a fixture in the [tomhennen/wrangle-test](https://github.com/TomHennen/wrangle-test) companion repo. Without this, the integration test doesn't exercise the type, and bugs that only surface in real CI (permission cascades, output bindings, attestation/verification interactions) don't get caught.

The canonical reference is `tomhennen/wrangle-test/.github/workflows/test-wrangle.yml.template`. Read it before writing yours — there's more than the per-type job:

- The template uses `__WRANGLE_SHA__` placeholder substituted by the dispatch script.
- Several jobs (currently `test-shell`, `test-container`, `test-python`, `test-python-uv`, `test-scan`) run in parallel against fixtures in matching directories.
- Some build types need supporting jobs around the wrangle call. Examples below.

### Minimal fixture (validation-only or simple types)

```
<type>/
├── <ecosystem-required-file>     # e.g., go.mod, package.json
├── src/                          # minimal source
└── tests/                        # minimal tests (if applicable)
```

Plus a job in the template:

```yaml
test-<type>:
  permissions:
    # The exact set depends on what wrangle's reusable workflow's nested jobs declare.
    # Read that reusable workflow and grant the UNION at startup — GitHub
    # validates even jobs that will skip at runtime. See Common Gotchas below.
    id-token: write   # OIDC for Sigstore keyless signing (attest + VSA)
    attestations: write   # wrangle's attest job writes GitHub-issued SLSA provenance
    contents: write   # VSA attached to the GitHub release (npm/go/python); container uses packages: write instead
  uses: TomHennen/wrangle/.github/workflows/build_and_publish_<type>.yml@__WRANGLE_SHA__
  with:
    path: <type>
```

### Realistic fixtures need supporting jobs

Two patterns the existing types need that aren't visible from the minimal example:

**Python:** `prep-python` pushes a version-bump commit before the build so `test-python` exercises wrangle's `ref:` input (building a commit pushed after the trigger). Publishing to a registry is exercised by the **showcase** (post-merge, tag-driven), not the per-PR integration test — publish must live in the calling workflow because Trusted Publishing's OIDC token binds to the caller's filename ([pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096)), and npm allows only one trusted publisher per package, so a single workflow owns the publish slot. Multiple variants (`python/` for pip, `python-uv/` for uv) exist as separate fixtures with parallel `test-python` / `test-python-uv` jobs.

**Container:** the `test-container` job passes `secrets: { gh_token: ${{ secrets.GITHUB_TOKEN }} }` because the container reusable workflow needs a token for GHCR operations (registry login, pushing the attestation and VSA referrers).

If your build type has analogous needs (per-run version uniqueness, separate publish path, secrets forwarding, ecosystem-specific workarounds), build them into your fixture from the start. Don't try to make a minimal fixture work and then graft these on later — that's a multi-PR coordination cycle each time.

### Variants

If your build type has multiple variants worth exercising (e.g., python's pip vs uv paths), add a second fixture (`<type>-<variant>/`) and a parallel job, both with the same permissions block.

## Common gotchas (the retrospective)

Lessons from container/shell/python that the next build type should *expect* to hit:

### Permission cascade through nested reusable workflows

GitHub validates a called reusable workflow's job-level permissions at workflow startup, regardless of any `if:` condition that might skip the job. The caller (your example workflow's `build:` job; wrangle-test's `test-<type>:` job) must grant every scope every called job declares — even when those jobs would skip at runtime.

Wrangle's reusable workflows run an `attest:` job (`actions/attest-build-provenance`) that writes GitHub-issued SLSA provenance, and a `vsa:` job that emits a signed VSA. Together they need:

- **`id-token: write`** — OIDC for Sigstore keyless signing (both the provenance attestation and the VSA).
- **`attestations: write`** — for the `attest:` job to write the provenance to GitHub's attestation store.
- **`contents: write`** — for the `vsa:` job to attach the VSA to the GitHub release (npm/go/python). This is *not* the old generator's `upload-assets` requirement — there is no generator upload job anymore. The container verify job stores the VSA in the registry instead, so container callers grant **`packages: write`** (which the attest job also reuses to push the attestation referrer to GHCR) rather than `contents: write`.

**What to do:** Read the reusable workflow you're calling, identify every permission its jobs declare, and grant the union in your reusable workflow's caller AND in the example workflow AND in the wrangle-test fixture's job. PR #156 hit this three times before getting it right.

### Reusable-workflow output names

The reusable workflow exposes `provenance-artifact-name` (the Sigstore bundle the `attest:` job uploads), `metadata-artifact-name`, and any type-specific outputs (e.g. `dist-artifact-name`). Read the workflow's `workflow_call.outputs` block in its actual source — don't infer names from documentation summaries.

### Cosign keyless verification identity is branch-dependent

If your build type Cosign-verifies a third-party tool's release (the way `tools/syft/install.sh` does), the certificate identity is anchored to whichever ref the upstream's release workflow ran on — usually a branch like `main`, NOT a tag matching the version. PR #156 fixed this in `ba6dfa6` after Cosign rejected every signature because the identity expected `@refs/tags/v*` but the upstream signs from `refs/heads/main`. Read the upstream's release workflow to confirm the ref before pinning the identity.

### Path validation belongs in `lib/validate_path.sh`

Don't reinvent. Both container and python now delegate. New build types do the same.

### Implement minimally before adding fallback paths

PR #156 shipped a `setup.py`-only fallback in python's `validate_inputs.sh` that didn't actually work — `actions/setup-python`'s `python-version-file` requires `pyproject.toml` regardless. The fallback only got removed after a later review pass caught it. Generalize: don't add an "also handle X" branch unless you've end-to-end-tested that branch. A minimal happy path that works beats a multi-path implementation where one path is broken.

### The example workflow MUST be exercised end-to-end before merge

Don't trust grep-based bats tests for the example. PR #156 almost shipped an example workflow with the wrong permissions (would have failed at startup for every adopter on first run); the bug was caught only because reviewer asked about end-to-end testing. The wrangle-test integration test covers wrangle-test's template, not the example — so the example is its own verification surface.

Concrete check before merge: copy the example workflow into a scratch repo or compare it byte-for-byte with the wrangle-test fixture. If the permissions block differs from what wrangle-test grants, one of them is wrong.

### The composite-action SHA pin in the reusable workflow lags every commit

`build_and_publish_<type>.yml` references the composite action by SHA: `TomHennen/wrangle/build/actions/<type>@<sha>`. Every commit that changes the composite needs a follow-up commit (or atomic same-PR commit) bumping this pin — otherwise the reusable workflow keeps pulling stale composite code, and the integration test passes the unit tests but exercises the *old* composite.

PR #156 shipped at least three pin-bump commits (`8485af3`, `830540e`, `049fb5d`) interleaved with composite-changing commits. PR #167 needed a similar dance.

**Use `make bump-action-pins`** when it lands (PR #166 / issue #165). Idempotent, no-op if pins are already current. Until then, bump pins manually in the same PR as the composite change. CI's `dispatch` job is the early-warning system: if the integration test passes but only because it's running the old composite, your tests are lying.

### wrangle-test fixture coordination is a multi-PR dance

Permission or fixture-structure changes usually require:

1. A wrangle-test PR to add/update the fixture and template
2. A wrangle PR that depends on that PR being merged

Plan for the latency. PR #156 needed three wrangle-test PRs (fixture, permission grants, and the python-uv variant) interleaved with wrangle pushes.

## Decisions to inherit (cross-references)

These are wrangle-wide decisions a new build type should follow without rethinking. **Caveat:** wrangle is GitHub-Actions-native today. Whether the contract should change for portability to non-GitHub CI/CD systems (Jenkins, GitLab, CircleCI, etc.) is an open architectural question tracked in [#171](https://github.com/TomHennen/wrangle/issues/171). Until that lands, follow the GHA-shaped patterns below; if portability becomes the design, the runbook updates with it.

- **Unified metadata layout** — every build type writes to `metadata/<type>/<shortname>/` and uploads as `<type>-metadata-<shortname>`. See [`docs/SPEC.md`](./SPEC.md) "Unified metadata layout" and [#150](https://github.com/TomHennen/wrangle/issues/150). *Convention is canonical once #167 merges; container's existing `container-build-results-<shortname>` upload is being renamed there.*
- **Provenance gating** — `if: ${{ ! startsWith(github.event_name, 'pull_') }}` is the default and what every build type uses today. A configurable input (`provenance-events` or similar) is *proposed* in [#161](https://github.com/TomHennen/wrangle/issues/161); until it lands, override by editing the `if:` directly in your reusable workflow if you need different gating.
- **Action SHA pinning** — full SHA refs for `TomHennen/wrangle/...` (forks pending [#137](https://github.com/TomHennen/wrangle/issues/137) / `$/` syntax [#136](https://github.com/TomHennen/wrangle/issues/136)). `make bump-action-pins` is in flight (PR #166); manual bumps until then.
- **Test patterns** — start with structural bats tests for the YAML and helpers; add behavioral tests for any extracted scripts. The integration test in wrangle-test exercises end-to-end. See [#160](https://github.com/TomHennen/wrangle/issues/160) for the broader test-quality cleanup.
- **No `curl | sh`, no `/usr/local/bin`** — install scripts use `lib/download_verify.sh` and install to `$WRANGLE_BIN_DIR`. CLAUDE.md is the canonical source.
- **Permissions are minimal** — `permissions: write-all` is forbidden. Each job declares only what it needs. The reusable workflow declares only what its inner jobs need.

## Updating this runbook

When your PR surfaces a new lesson, update this runbook in the same commit. Capturing fresh lessons is the cheap part. If a section here is wrong or stale, fix it — don't write around it.

## PR readiness checklist

Before requesting review on a new build-type PR, verify:

- [ ] `./test.sh` passes locally.
- [ ] No stale `TomHennen/wrangle/...@<sha>` refs in `.github/workflows/` (run `make bump-action-pins` once it ships, or bump manually for now).
- [ ] No `@main` ref in any new file (CLAUDE.md rule — third-party actions pin to SHA, internal references pin to SHA or use the relative `./` path).
- [ ] `build/actions/<type>/{action.yml, SPEC.md, README.md, test.bats}` all exist (artifact-producing types). Validation-only types may ship without `SPEC.md`/`README.md` initially but should plan to add them.
- [ ] Reusable workflow at `.github/workflows/build_and_publish_<type>.yml` (artifact-producing) or `build_<type>.yml` (validation-only).
- [ ] Example at `gh_workflow_examples/build_<type>.yml`. Permissions block byte-for-byte matches the corresponding job in `tomhennen/wrangle-test/.github/workflows/test-wrangle.yml.template`. (Differing means one of them is wrong.)
- [ ] `build/README.md` has a section pointing at the new README.
- [ ] `gh_workflow_examples/README.md` has a one-line entry for the new example.
- [ ] `docs/SPEC.md`'s build-type table (under "Build type extensibility") marks the new type as available.
- [ ] No inline `run:` blocks longer than ~5 lines or containing logic in `action.yml`. Helper scripts live in `build/actions/<type>/`.
- [ ] Path validation delegates to `lib/validate_path.sh`.
- [ ] Metadata is written to `metadata/<type>/<shortname>/` and uploaded as `<type>-metadata-<shortname>` (post-#167 convention).
- [ ] Reusable workflow exposes `metadata-artifact-name`, `provenance-artifact-name` (the attest job's Sigstore bundle, for artifact-producing types), and any type-specific outputs (e.g., `dist-artifact-name` for python).
- [ ] Integration fixture exists in `tomhennen/wrangle-test` and a `test-<type>:` job is in the template. Permissions cascade through nested reusable workflows is verified (see Common Gotchas).
- [ ] **End-to-end verification:** `gh attestation verify` (or the build type's VSA) actually succeeds against an artifact your build type produced. The integration test exercises this; if it doesn't, fix the test before requesting review.
- [ ] **wrangle-test CI run on the integration branch is green** (not just unit tests on the wrangle PR side — the full `dispatch` job).
- [ ] If your PR surfaced a new lesson, this runbook is updated in the same commit.
