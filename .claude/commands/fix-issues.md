---
description: Coordinate parallel fixes for several issues — one background worktree agent per issue, an independent reviewer per PR. You stay the reviewer of last resort; your context stays thin.
argument-hint: <issue> [issue ...]  (GitHub issue numbers, optionally each with a short note)
allowed-tools: Agent, SendMessage, Bash(gh issue view:*), Bash(gh pr view:*), Bash(git fetch:*), Bash(git log:*), Bash(git diff:*)
---

You are the **coordinator**. You dispatch and route; you do **not** fix issues yourself or read their diffs. Your context is a scarce resource — you hold issue→agent→PR mappings and one-line statuses, nothing more. Everything heavy (reading code, editing, testing, reviewing) happens inside subagents whose output to you is capped at one line.

## Issues to coordinate

$ARGUMENTS

If the list is empty, ask which issues to fix and stop.

## Phase 0 — Triage & conflict plan (do this before dispatching)

1. `git fetch origin` and note `origin/main`'s short SHA — every agent branches from there.
2. `gh issue view <n>` each issue and predict which files/areas it will touch.
3. **Group issues that plausibly modify the same files.** Issues in different areas are independent → run in **parallel**. Overlapping issues → run **sequentially**: the second agent branches off the first's branch (a stacked PR) and its PR body notes the dependency, so they don't race the same lines. If overlap is ambiguous, show the user your grouping and let them adjust before launching. You cannot perfectly predict conflicts from issue text — say so, and note that each agent rebases on fresh `origin/main` and flags any conflict it hits.
4. **Pacing:** running tests is heavy. Launch parallel agents in waves of at most 3; wait for a wave's completions before the next.

## Phase 1 — Dispatch author agents

For each issue, spawn **one** `Agent` with `isolation: "worktree"` and `run_in_background: true`, using the **Author template** below. Give each a stable, memorable `label` (e.g. `fix-123`) — that label is how you and the user address it later. Send all spawn calls for a wave in a single message so they run concurrently.

## Phase 2 — Independent review (per PR)

When an author agent reports a PR, spawn a **separate** `Agent` (the **Reviewer template**) against that PR — fresh context, no stake in the code. Route its findings back to the author agent via `SendMessage` to its label; the author addresses them and the **same** reviewer re-verifies (the repo requires re-verification by the original reviewer). Only surface a PR to the user as *ready* once the independent reviewer approves. Keep both agents alive for follow-ups.

## Phase 3 — Report & hand off

Print a table: `issue | agent label | review | PR | status`. Then tell the user how to direct the agents:

- *"Ask `fix-123` to also handle the nil case"* / *"What did `fix-123` decide about X?"* → you relay via `SendMessage` to that label and report back its one-line answer. The agent still has its worktree and full context, so it can answer questions **or push follow-up commits** to its PR.
- Remind them: **nothing is merged.** Each PR needs their review and an owner `LGTM`.

---

## Author template

> You are fixing a single issue in the wrangle repo in your own git worktree. Read `CLAUDE.md` and `docs/SPEC.md` first — wrangle is a supply-chain security tool; its own code must be exemplary.
>
> **Issue:** `<ISSUE>` (a GitHub issue number unless told otherwise — `gh issue view <ISSUE>`; if it's a beads id, `bd show <ISSUE>`).
>
> **Hard rules — violating any makes your work worse than nothing:**
> - Branch off **fresh `origin/main`** (`git fetch origin && git checkout -b claude/<slug>-<ISSUE> origin/main`) unless the coordinator told you to stack on another branch. Never branch from local `main`.
> - **Never merge, never enable auto-merge.** An owner `LGTM` is required before any wrangle PR merges. You open the PR and stop.
> - **Verify before you push, using the most complete layer this environment supports.** If Docker is available, run `./test.sh` (full) and make it pass (`./test.sh quick` for inner-loop). If the container can't run here (no Docker — e.g. a web/sandbox session), run the narrowest relevant checks you can and **state plainly in your status that the containerized suite did not run locally.** CI runs the same checks on the PR and is authoritative — never push red, and never claim a pass you didn't observe.
> - **Self-review** against the CLAUDE.md checklist (SPEC adherence, no needless complexity, supply-chain discipline, shell preamble + quoting, no expression injection, minimum permissions, pin-drift) and fix what you find — this is in addition to the independent review you'll receive.
> - If you changed a composite action a reusable workflow consumes, a self-ref **bootstrap pin** may be needed (CLAUDE.md §Dogfooding, docs/e2e_testing.md). Don't run the full pin lifecycle — note in your status that a pin bump is required after merge.
> - Commit messages end with the `Co-Authored-By` trailer; the PR body ends with the `Generated with Claude Code` line and **its first line is prefixed `claude:`**. `gh pr create` targeting `main`.
>
> **Stay available.** The coordinator may `SendMessage` you with review findings or the user's follow-up questions. Address findings and answer questions on the *same* branch/PR; keep your worktree.
>
> **Your reply reaches only the coordinator's context, and it is the ONLY thing that does.** Reply with EXACTLY one line — no diff, no summary, no narration:
> `#<ISSUE> — <DONE|BLOCKED> — <PR url, or one-line blocker reason> [— note: tests not run locally / pin bump needed, if applicable]`

## Reviewer template

> You are an **independent** reviewer of PR `<PR>` in the wrangle repo — you did not write it. Review the diff (`gh pr diff <PR>`) against `CLAUDE.md` (esp. the Code review checklist) and `docs/SPEC.md`: correctness, SPEC adherence, supply-chain discipline, needless complexity, and whether it makes adopters' lives easier. Post concrete, actionable findings as inline PR comments (`claude:`-prefixed). Do not approve work you didn't actually verify; do not nitpick style a linter already enforces.
>
> When asked to re-verify after the author responds, check only whether each finding was resolved.
>
> **Reply to the coordinator with EXACTLY one line:** `PR <PR> — <APPROVE|CHANGES:n> — <one-line gist>`
