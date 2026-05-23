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

**Tracking tags `vYYYYMMDD-<wrangle-sha7>` — automatic.**
`.github/workflows/release-showcase.yml` (in this repo) fires on
every push to `main` and runs `test/integration/push_showcase_tag.sh`,
which only pushes a new tracking tag when there's an actual `git diff`
between HEAD and the wrangle SHA embedded in the most recent tracking
tag. Doc-only commits trigger an evaluation but no tag/run. The date
in the tag name is the **commit's committer date**, not wall-clock,
so reruns of the same commit are idempotent across UTC midnight.
Tracking tags produce pre-release Releases on the companion side and
are pruned after 30 days (see companion's `showcase.yml`).

**Curated tags `vX.Y.Z` — manual.** When you want a stable, clickable
example artifact to link from wrangle's docs, cut a curated release in
the companion repo via GitHub's **Draft a new release** UI (or
`git tag vX.Y.Z && git push origin vX.Y.Z`). The same `showcase.yml`
runs, the resulting Release is a full release (not a pre-release),
and curated releases are **never** pruned — they're the linkable
artifacts.

### The tag/test asymmetry (loud)

A tracking tag's **name** embeds the wrangle commit SHA, but the
showcase **run** that the tag fires exercises whatever
`tomhennen/wrangle-test/main` is at the moment the tag is pushed.
The tag's target commit is wrangle-test's main HEAD, *not* a snapshot
tied to the wrangle SHA in the tag name. Consequence: if wrangle-test
main moves between two consecutive wrangle pushes, two adjacent
tracking tags will name two wrangle SHAs but reflect different
wrangle-test states.

This is intentional. The showcase is a **current-state heartbeat** —
"does wrangle@latest still work against wrangle-test@latest in real
GitHub Actions infrastructure?" — not a reproducibility artifact. If
you need reproducible builds, look at the curated `vX.Y.Z` releases
where both repos are at known commits.

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

- Tracking-tag retention is **30 days**, enforced by a `prune-tracking-tags`
  job in the companion's `showcase.yml`. The prune filters strictly on
  the `vYYYYMMDD-<sha7>` regex AND on `prerelease: true`, so a hand-cut
  `vX.Y.Z` (full release) is never touched even if someone mistypes the
  date. Adjust the retention window by editing `KEEP_DAYS` in the
  companion workflow.
- Tags pushed by `GITHUB_TOKEN` do not trigger downstream `on: push:
  tags` workflows (GitHub's recursion guard) — a PAT is required.
- Trigger is unconditional (no `paths:` filter). The runtime diff in
  `push_showcase_tag.sh` does the actual gating, which means no
  hand-maintained allowlist to drift.

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
