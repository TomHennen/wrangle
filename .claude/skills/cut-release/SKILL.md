---
name: cut-release
description: >
  Operator runbook for cutting a wrangle release tag (vX.Y.Z) of TomHennen/wrangle.
  Covers pin convergence, the adopter version-ref bump, milestone/dependabot hygiene,
  and the three pre-tag gates (working showcase, owner sign-off, empirically-verified
  verify commands). Use when preparing or cutting a release, or when asked "what's left
  to ship vX.Y.Z?". This is the runnable procedure; rationale and tag-immutability setup
  live in docs/RELEASING.md.
---

# Cut a wrangle release

This is the *operator checklist*. The **why** (showcase model, milestone semantics,
tag-immutability controls, ordering constraints) lives in
[docs/RELEASING.md](../../../docs/RELEASING.md) — read it once, then drive from here.
Pin lifecycle and the `check_pin_ancestry` control are in
[docs/e2e_testing.md](../../../docs/e2e_testing.md).

## Ground rules (non-negotiable)

- **The tag is the owner's call.** Do every prep step, then stop and wait for an
  explicit "cut it" from the repository owner. Never tag on your own initiative.
- **No merge without an owner `LGTM`.** Green CI is never authorization to merge. Every
  release-prep PR follows the normal review path, including adversarial subagent review.
- **A bare `git tag && git push` is not a release.** It creates a loose tag with no
  GitHub Release and therefore no attestation. Always `gh release create vX.Y.Z`.
- Run from a **clean checkout of `main`** (`git status` clean, `gh auth status` good).
  Do not drive a release from a nested worktree.

## Phase 1 — Converge self-reference pins to `main`

Wrangle's actions pin each other by SHA. Before a release, every self-ref pin must
resolve to released `main` content **and** be labelled `# main` — not a feature branch.

```bash
git switch main && git pull --ff-only
tools/converge_action_pins.sh          # bump → commit → repeat until reachable AND fresh
```

- `converge_action_pins.sh` can emit **more than one commit** (one per nesting level).
  Land them via a PR merged as a **merge commit — never a squash** (direct pushes to
  `main` are blocked by branch protection), or the intermediate branch-SHA pins re-orphan
  and `main` goes red.
- **Footgun — pin labels.** `bump_action_pins.sh` writes `# main` only when the target
  SHA is an ancestor of local `main`; otherwise it writes the *current branch name*. So
  bump/converge **after** the content is on `main` (or run detached at `origin/main`) to
  get `# main` labels. A pin labelled `# some-branch` is the tell that this was skipped.
- **`check_pin_freshness` is content-based** — it ignores pin-SHA-only diffs, so CI can
  be green while the pin SHAs/labels are stale. Green CI does **not** prove pins are on
  `main`. Confirm by eye:

```bash
# subshell keeps self_ref_pin_paths.sh's `set -euo pipefail`/`set -f` out of your shell
mapfile -t dirs < <(bash -c 'source tools/self_ref_pin_paths.sh; wrangle_self_ref_pin_paths')
git grep -nE 'TomHennen/wrangle.*@[0-9a-f]{40}' -- "${dirs[@]}" \
  | grep -vE '# main' || echo "all self-ref pins labelled # main"
```

> Until the pin-on-`main` release guard (#592) lands, this check is **manual** — do it.

## Phase 2 — Bump adopter-facing version refs

Adopters pin wrangle's reusable workflows at a release tag. Bump every adopter-facing
tag pin from the current latest to the new version. There's no helper script and no
hardcoded list — discover the surface each time, then replace and review the diff:

```bash
PREV=$(gh release view --json tagName -q .tagName)   # current latest
NEW=v0.0.0                                            # set to the release you're cutting
grep -rlE "TomHennen/wrangle[^ ]*@${PREV}" \
  --include='*.yml' --include='*.yaml' --include='*.md' . | grep -v '\.claude/'
```

The surface is the example workflows, the per-build-type and action READMEs, the
top-level README, and `docs/` (incl. policy-locator URLs). Don't hand-maintain that list:
`test/test_pin_consistency.bats` fails closed if any adopter-facing pin disagrees on the
version, so the grep above is the source of truth. Leave third-party action refs and test
fixtures alone. The bump is a normal PR — owner `LGTM` required.

## Phase 3 — Milestone & dependabot hygiene

- **Milestone must be clean** before the minor tag — zero open issues, zero open PRs:

  ```bash
  gh issue list --milestone vX.Y.Z --state open
  gh pr  list  --search "milestone:vX.Y.Z" --state open
  ```

  (A merged milestone issue ships in the next `0.2.x`; the minor tag is cut only when the
  whole milestone scope is done — see RELEASING.md § Release train.)
- **Triage dependabot PRs.** Most pending bumps are stale by release time; close the
  outdated ones. Honour the **7-day cooldown** (WL005) — never adopt a brand-new upstream
  version as part of cutting a release.

## Phase 4 — The three release gates

All three must hold before you ask the owner to cut. Do not shortcut.

1. **A properly functioning showcase.** A green end-to-end showcase run on the release
   content in [`TomHennen/wrangle-test`](https://github.com/TomHennen/wrangle-test). The
   `main` heartbeat builds `@refs/heads/main` (so the *strict* consumer policy rejects it
   by design — that path uses the non-strict gate); the consumer-verifiable curated
   artifact is built at the release tag. Watch for a wedged showcase job stalling the
   `showcase` concurrency group; cancel a hung job (releases persist) to free the queue.
2. **Explicit owner sign-off on release contents.** Present exactly what's in the release
   (the milestone, the diff highlights) and get an explicit yes — separate from "cut it".
   Also confirm the curated tool-image catalog is fresh — no entry is behind its
   published `:latest` (the §11 release precondition):

   ```bash
   ./tools/check_catalog_freshness.sh   # exit 0 in-sync; 1 drift (bump per its remediation); 2 registry unreachable
   ```

   On drift (exit 1), run the printed `tools/bump_catalog_digest.sh <tool> <digest>`,
   land it as a normal PR under the cooldown, then re-check. (Adoption-lag only —
   it does not prove the digest was built from current source.) **Exit 2
   (registry unreachable) means the precondition is UNVERIFIED — do not proceed.**
   Retry until the result is 0 or 1; a visible exit-2 is not a satisfied gate.

   Then confirm each digest was built from the **current** tool source (the
   stronger §11 guarantee the adoption-lag check does not prove — and the gate
   for the containerized signing path, #633). Run on a full-history checkout
   (`git fetch --unshallow` if shallow):

   ```bash
   ./tools/check_catalog_provenance_freshness.sh   # 0 fresh; 1 a digest's source changed since its build; 2 backend unreachable
   ```

   On exit 1, the pinned image predates a change to its tool source (`tools/<tool>/`,
   `lib/`, or `tools/go.mod`/`go.sum`): re-publish the image, then bump the catalog
   digest, then re-check. **Exit 2 fails closed — the precondition is UNVERIFIED,
   do not proceed** (the blocking gate inverts the weekly advisory workflow, which
   warns on exit 2).
3. **Empirically-verified download + verify commands.** Re-run the consumer
   download-and-verify recipe in
   [docs/verifying_artifacts.md](../../../docs/verifying_artifacts.md) against a **real**
   release artifact this cycle (ampel, cosign, `gh attestation`, by-digest). Commands
   drift — never assert an untested command. Fix the doc if a recipe breaks.

## Phase 5 — Cut the tag and publish the Release

Only after the owner says "cut it". First write the notes **benefit-first, second
person** — what the adopter gains, not a changelog of internal wins or code structure;
mention the producer/consumer policies that let adopters check the evidence. Then:

```bash
gh release create vX.Y.Z --target <commit> --title vX.Y.Z --notes-file release-notes.md --latest
```

- Pick the exact `main` commit that carries the converged pins and bumped refs.
- Pass the hand-written notes via `--notes-file`. Don't use `--generate-notes` for the
  final notes — it emits an auto-changelog, not the benefit-first prose.
- Tag immutability (immutable releases + a no-bypass tag ruleset) is **already configured
  on the repo** — one-time setup, not redone per release (see RELEASING.md).
- `goreleaser` needs a semver-parseable tag — `vX.Y.Z` is fine; never a `pr-<n>` form.

## After cutting

- Confirm `gh release view vX.Y.Z` shows `--latest` and the showcase links resolve.
- Roll deferred work into the next milestone; file follow-ups rather than holding the tag.
