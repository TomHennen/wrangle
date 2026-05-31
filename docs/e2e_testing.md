# End-to-End Testing & the Showcase

Wrangle's reusable workflows are exercised end-to-end in three places. This is the operator's view of how they fit together and the one process wrinkle they create — bootstrap-pinning a change to a self-referenced action or policy. The integration test's *design and contracts* live in [test/integration/SPEC.md](../test/integration/SPEC.md); this document is about running the system, not specifying it.

## The three layers

- **Dogfooding** — wrangle runs its own workflows on its own repo (`check_source_change.yml`, `build_shell.yml`). If a feature doesn't work on wrangle itself, it is broken. Covers only the build types wrangle actually *is* (shell, source-change), not npm/python/container/go.
- **Integration test (PR-time)** — on every internal PR, `integration-test.yml` runs `test/integration/dispatch.sh`, which pushes an ephemeral branch to the companion repo (`tomhennen/wrangle-test`) and waits for the companion's run to pass. It is the only e2e coverage for the build types wrangle can't dogfood. Design + threat model: [test/integration/SPEC.md](../test/integration/SPEC.md).
- **Showcase (post-merge)** — `release-showcase.yml` fires on **every push to `main`** and, via `push_showcase_tag.sh`, pushes a `vYYYYMMDD-<sha>` tracking tag to the companion repo whenever wrangle's source changed since the last tag. The companion's `showcase.yml` then runs the reusable workflows against a real release. This is an **unattended heartbeat** — it runs automatically on the merge commit, with no human in the loop.

That last fact — the showcase running unattended on the merge commit — is what shapes the bootstrap-pin lifecycle below.

## Bootstrap pins: changing a self-referenced action or policy

### Why a normal PR can't test it
wrangle's reusable workflows call wrangle's own composite actions by SHA-pinned self-reference: `uses: TomHennen/wrangle/actions/<name>@<sha>`. GitHub resolves a *nested* self-reference from its pinned SHA — which points at **main** — not from the PR head. The integration test substitutes the PR head SHA only into the *top-level* workflow call. So a PR that changes a composite action (or a file it reads at runtime, e.g. a `policies/*.hjson` PolicySet) and wires it into a reusable workflow would have the integration test run the **old, main** action against inputs that only exist on the branch — failing on code the PR didn't ship.

### The temporary fix
For the duration of the PR, point that one nested pin at a branch SHA that carries the change:

1. Hand-edit just the affected `actions/<name>` pin — leave unrelated pins on their main SHA, so the post-merge surface is one pin, not all of them.
2. Make the pin edit the **last** commit, so it targets a SHA that already contains the action/policy.
3. Note the bootstrap pin in the PR description.

`tools/check_pin_ancestry.sh` (run in the `integration` CI job with `fetch-depth: 0`) asserts every wrangle self-ref pin is reachable from `HEAD`. On the PR the branch SHA is an ancestor of the branch, so it is **green**.

### Lifecycle: leave it on the initial PR, bump after merge
A branch SHA can't become a real main SHA until the code is on main, so the bump is always a post-merge step. **How you merge the initial PR decides when you must bump:**

| Merge mode | What happens on main | When to bump |
|------------|----------------------|--------------|
| **Merge commit** (recommended for a bootstrap-pin PR) | The branch SHA stays an ancestor of main, so the pin resolves, the showcase works, and `check_pin_ancestry` stays **green**. | At leisure — a following or dedicated PR runs `tools/bump_action_pins.sh <main-sha>`. The bump is cosmetic: it repoints to a clean main SHA and fixes the `# <branch>` comment label to `# main`. |
| **Squash** | The branch SHA is orphaned (never an ancestor of main), so `check_pin_ancestry` goes **red** and the unattended showcase can't resolve the action. | Promptly — the red check is the forcing function; bump before relying on main. |

`check_pin_ancestry` is the control in both cases: **green means safe to defer, red means bump now.** It cannot be silently forgotten — a forgotten, mistyped, or squash-orphaned pin fails CI on main rather than degrading quietly.

### Recovery
If `check_pin_ancestry` is red on main (or a showcase run failed to resolve a wrangle action):

1. `tools/bump_action_pins.sh <main-sha>` — repoints every wrangle self-ref pin to a SHA reachable from main.
2. Push it (a dedicated one-line bump PR, or fold it into the next PR).
3. The check goes green and the next showcase resolves the action.
