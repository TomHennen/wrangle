# End-to-End Testing & the Showcase

Wrangle's reusable workflows are exercised end-to-end in three places. This is the operator's view of how they fit together. The integration test's *design and contracts* live in [test/integration/SPEC.md](../test/integration/SPEC.md); this document is about running the system, not specifying it.

## The three layers

- **Dogfooding** — wrangle runs its own workflows on its own repo: `local_build_shell.yml` calls `build_shell.yml`, which embeds the source scan and runs the integration bats suites via `test/setup_integration.sh`. If a feature doesn't work on wrangle itself, it is broken. Covers only the build type wrangle actually *is* (shell), not npm/python/container/go.
- **Integration test (PR-time)** — on every internal PR, `integration-test.yml` runs `test/integration/dispatch.sh`, which pushes an ephemeral branch to the companion repo (`tomhennen/wrangle-test`) and waits for the companion's run to pass. It is the only e2e coverage for the build types wrangle can't dogfood. Design + threat model: [test/integration/SPEC.md](../test/integration/SPEC.md).
- **Showcase (post-merge)** — `release-showcase.yml` fires on **every push to `main`** and, via `push_showcase_tag.sh`, pushes a `vYYYYMMDD-<sha>` tracking tag to the companion repo whenever wrangle's source changed since the last tag. The companion's `showcase.yml` then runs the reusable workflows against a real release. This is an **unattended heartbeat** — it runs automatically on the merge commit, with no human in the loop.

## Self-references follow the calling ref

wrangle's reusable workflows call wrangle's own composite actions with GitHub's self-repository syntax: `uses: $/actions/<name>`. GitHub resolves that to wrangle's repository at the exact commit the workflow itself is running from, at every nesting level (`workflow → verify_release → verify`, `scan → tools/*`).

So each layer exercises one consistent commit: the integration test substitutes the PR head SHA into the top-level workflow call and every nested action comes from that same PR head; the showcase runs `main`; an adopter pinned at `@vX.Y.Z` runs the tag's own actions and policies. A PR that changes an action and the workflow wiring it in needs no special handling. `wrangle-workflow-lint` (WWL004) rejects an owner/repo self-reference, which would resolve a fixed ref instead.
