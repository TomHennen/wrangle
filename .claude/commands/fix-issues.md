---
description: Coordinate parallel fixes for several issues — one background worktree agent per issue, each opens a PR. You stay the reviewer; your context stays thin.
argument-hint: <issue> [issue ...]  (GitHub issue numbers, optionally each with a short note)
allowed-tools: Agent, Bash(gh issue view:*), Bash(git fetch:*), Bash(git log:*), TaskList, TaskGet
---

You are the **coordinator**. Your job is to dispatch one isolated agent per issue and report back — **not** to fix the issues yourself and **not** to read their diffs. Protecting your own context is a hard requirement: you hold PR links and one-line statuses, nothing more.

## Issues to coordinate

$ARGUMENTS

If the list is empty, ask the user which issues to fix and stop.

## How to dispatch

1. Confirm the base is fresh: `git fetch origin` and note `origin/main`'s short SHA. Every agent branches from there, never from local `main`.
2. For **each** issue, spawn **one** `Agent` with `isolation: "worktree"` and `run_in_background: true`, using the subagent prompt template below (substitute the issue number/note). Send all the spawn calls in a single message so they run concurrently.
3. **Pacing:** each agent runs the full containerized `./test.sh`, which is heavy. For more than 3 issues, tell the user you're staggering and launch in waves of 3 — wait for a wave's completion notifications before launching the next.
4. As each agent finishes, the harness notifies you with that agent's final message (a one-line status + PR URL — that's all it returns). Relay it into a running table. **Do not** open the PRs, read the diffs, or pull the branches. If an agent reports BLOCKED, surface its one-line reason and move on; don't dig in unless the user asks.
5. When all are done, print a final table: `issue | status | PR`. Remind the user that nothing is merged — each PR needs their review and an owner `LGTM` before it can land.

## Subagent prompt template

> You are fixing a single issue in the wrangle repo, working in your own git worktree. Read `CLAUDE.md` and `docs/SPEC.md` first — wrangle is a supply-chain security tool and its own code must be exemplary.
>
> **Issue:** `<ISSUE>`  (a GitHub issue number unless told otherwise — run `gh issue view <ISSUE>` to read it; if it's a beads id, use `bd show <ISSUE>`).
>
> **Hard rules — violating any of these makes your work worse than nothing:**
> - Branch off **fresh `origin/main`**: `git fetch origin && git checkout -b claude/<short-slug>-<ISSUE> origin/main`. Never branch from local `main`.
> - **Never merge, and never enable auto-merge.** An owner `LGTM` is required before any wrangle PR merges (CLAUDE.md). You open the PR and stop.
> - Run `./test.sh` and make it pass before you push (`./test.sh quick` for inner-loop iteration, but the full suite must pass before the PR). CI runs the same checks; do not push red.
> - **Self-review before opening the PR**, against the CLAUDE.md code-review checklist (SPEC adherence, no needless complexity, supply-chain discipline, shell preamble + quoting, no expression injection, minimum permissions, pin-drift). Fix what you find.
> - If you changed a composite action that a reusable workflow consumes, a self-ref **bootstrap pin** may be needed (CLAUDE.md §Dogfooding, docs/e2e_testing.md). Do **not** attempt the full pin lifecycle yourself — note in your PR status that a pin bump is required after merge.
> - Commit messages end with the `Co-Authored-By` trailer; the PR body ends with the `Generated with Claude Code` line and **its first line is prefixed `claude:`** so the owner can tell your posts from theirs.
> - Open the PR with `gh pr create` targeting `main`.
>
> **Your final message is consumed by a coordinator, not a human, and it is the ONLY thing that reaches the coordinator's context.** Return EXACTLY one line, nothing else — no diff, no summary, no narration:
> `#<ISSUE> — <DONE|BLOCKED> — <PR url, or one-line blocker reason>`
