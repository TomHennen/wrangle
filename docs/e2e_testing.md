# End-to-End Testing & the Showcase

Wrangle's reusable workflows are exercised end-to-end in three places. This is the operator's view of how they fit together and the one process wrinkle they create — bootstrap-pinning a change to a self-referenced action or policy. The integration test's *design and contracts* live in [test/integration/SPEC.md](../test/integration/SPEC.md); this document is about running the system, not specifying it.

## The three layers

- **Dogfooding** — wrangle runs its own workflows on its own repo: `local_build_shell.yml` calls `build_shell.yml`, which embeds the source scan and runs the integration bats suites via `test/setup_integration.sh`. If a feature doesn't work on wrangle itself, it is broken. Covers only the build type wrangle actually *is* (shell), not npm/python/container/go.
- **Integration test (PR-time)** — on every internal PR, `integration-test.yml` runs `test/integration/dispatch.sh`, which pushes an ephemeral branch to the companion repo (`tomhennen/wrangle-test`) and waits for the companion's run to pass. It is the only e2e coverage for the build types wrangle can't dogfood. Design + threat model: [test/integration/SPEC.md](../test/integration/SPEC.md).
- **Showcase (post-merge)** — `release-showcase.yml` fires on **every push to `main`** and, via `push_showcase_tag.sh`, pushes a `vYYYYMMDD-<sha>` tracking tag to the companion repo whenever wrangle's source changed since the last tag. The companion's `showcase.yml` then runs the reusable workflows against a real release. This is an **unattended heartbeat** — it runs automatically on the merge commit, with no human in the loop.

That last fact — the showcase running unattended on the merge commit — is what shapes the bootstrap-pin lifecycle below.

## Bootstrap pins: changing a self-referenced action or policy

wrangle's reusable workflows call wrangle's own composite actions by SHA-pinned self-reference: `uses: TomHennen/wrangle/actions/<name>@<sha>`. GitHub resolves a *nested* self-reference from its pinned SHA — which points at **main** — not from the PR head (the integration test substitutes the PR head SHA only into the *top-level* workflow call). So during a PR, a nested wrangle action always runs its **main** version, never the branch's.

### Default: leave the pins at main, bump after merge
This needs no special handling and is what nearly every PR does. A change to a self-referenced action that is backward-compatible just leaves the nested pins alone: the integration test exercises the main-pinned (old) action, which still passes; the change itself is covered by the action's own bats and by the post-merge showcase. After merge, routine `tools/bump_action_pins.sh <main-sha>` rolls every pin forward to the new code. The only thing you give up is pre-merge integration coverage *of that one action change* — an accepted gap.

### Bootstrap pin: only when the main-pinned action would fail
You need a bootstrap pin only when leaving the pin at main would make the integration test fail on code the PR didn't ship — i.e. the workflow now depends on something not yet on main: a **new** policy file the action reads, a new required behavior, or a change that makes the old action incompatible with the new wiring. (Example: the PR that introduced `policies/wrangle-provenance-v1.hjson` plus `actions/verify`'s policy-path resolution — main had neither, so the integration test couldn't pass without pointing at the branch.)

In that case, for the duration of the PR:

1. Hand-edit just the affected `actions/<name>` pin to a branch SHA that carries the change — leave unrelated pins on their main SHA.
2. Make the pin edit the **last** commit, so it targets a SHA that already contains the action/policy.
3. Note the bootstrap pin in the PR description.

### Merge however you like — the check tells you when to bump
A branch SHA can't become a main SHA until the code is on main, so a bootstrap pin is always bumped post-merge. You don't have to manage the merge method to make this safe — `tools/check_pin_ancestry.sh` (in the `integration` CI job, `fetch-depth: 0`) is the control. It resolves every wrangle self-ref pin at its pinned SHA — following the pins nested inside each composite at that SHA, not just the working-tree copy — and asserts each is reachable from `HEAD`: green on the PR (the branch SHA is an ancestor of the branch), and after merge:

- **Red on main** → a pin is unreachable (you squashed a bootstrap pin, or forgot a bump). Run `tools/bump_action_pins.sh <main-sha>` and push. Until you do, main is red and the unattended showcase can't resolve that action.
- **Green** → every pin resolves; bump at leisure (it just refreshes the SHA and the `# main` label).

A nested chain (`workflow → verify_release → verify`, `scan → tools/*`) takes one bump cycle per nesting level under squash: a commit can't pin itself, so editing an *inner* action needs the bump repeated until the check is green (#539). Because the check follows nested resolution, it stays red through the intermediate cycles rather than passing on a half-converged chain. Merging the bootstrap-pin PR as a **merge commit** keeps every branch SHA reachable, so a chain of any depth converges with no re-bump and no red window — a convenience, not a requirement.

### Recovery
If `check_pin_ancestry` is red on main (or a showcase run failed to resolve a wrangle action):

1. `tools/bump_action_pins.sh <main-sha>` — repoints every wrangle self-ref pin to a SHA reachable from main.
2. Push it (a dedicated one-line bump PR, or fold it into the next PR).
3. The check goes green and the next showcase resolves the action.
