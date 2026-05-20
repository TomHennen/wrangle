# Releasing

Two adopter-facing release flows touch wrangle. Both are tag-driven —
wrangle gates provenance-upload-to-Release on `refs/tags/*`, so only a
tag push produces a Release with the full SLSA L3 example artifacts.

## 1. Adopter-visible showcase artifacts

The companion repo
[`TomHennen/wrangle-test`](https://github.com/TomHennen/wrangle-test)
runs `showcase.yml` on every `v*` tag push, exercising every wrangle
reusable workflow end to end and publishing dist + SBOM + SLSA L3
provenance to the resulting GitHub Release. There are two flavors of
showcase tag:

**Tracking tags `vYYYYMMDD-<wrangle-sha>` — automatic.**
`.github/workflows/release-showcase.yml` (in this repo) pushes a
tracking tag to the companion whenever wrangle's reusable workflows,
composite actions, orchestrator, libs, or tool adapters change on
`main`. The resulting Release is marked as a pre-release so it stays
out of "Latest release." Freshness tracks actual wrangle changes — a
quiet week pushes no tags.

**Curated tags `vX.Y.Z` — manual.** When you want a stable, clickable
example artifact to link from wrangle's docs, cut a curated release in
the companion repo via GitHub's **Draft a new release** UI (or
`git tag vX.Y.Z && git push origin vX.Y.Z`). The same `showcase.yml`
runs, the resulting Release is a full release (not a pre-release), and
its dist / SBOM / provenance assets are the ones you link to.

### Prerequisites

- `TEST_REPO_PAT` secret on this repo, exposed to the
  `integration-test` environment. A fine-grained PAT (or GitHub App
  installation token) scoped to `contents: write` on `tomhennen/wrangle-test`
  and nothing else. The same secret powers `integration-test.yml`; the
  release-showcase workflow reuses it because the required scope is
  identical.
- The `integration-test` environment must permit `main` as a deployment
  branch (it does today; verify after editing the environment's branch
  rules).

### Operational notes

- Tracking tags accumulate on the companion repo (no pruning). At
  wrangle's current cadence this is ~tens per year — acceptable.
  Revisit if it becomes unwieldy; the pruning logic from the
  superseded `showcase-nightly-tag.yml` is a starting point in git
  history.
- Tags pushed by `GITHUB_TOKEN` do not trigger downstream `on: push:
  tags` workflows (GitHub's recursion guard) — a PAT is required.

## 2. Wrangle's own release tags

Wrangle's reusable workflows are pinned by adopters at a specific
release tag (`@vX.Y.Z`). Today these tags are cut manually:

1. Update the version reference in
   [`AGENTS.md`](../AGENTS.md) and any pinned `uses:` examples in
   `gh_workflow_examples/`.
2. Tag the release commit: `git tag vX.Y.Z && git push origin vX.Y.Z`.
   (Or use the **Draft a new release** UI; either creates the tag and
   fires any tag-listening workflows.)
3. After the tag exists, update the companion's
   `showcase.yml` to repoint its `@main` pins to `@vX.Y.Z`
   ([`wrangle-test#10`](https://github.com/TomHennen/wrangle-test/issues/10)).

Wrangle does not currently ship a release-helper workflow; tagging is
a release-management concern that belongs to the maintainer's chosen
versioning policy (semver here). If that changes, this section is the
place to document it.
