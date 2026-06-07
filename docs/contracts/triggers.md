# Trigger Model — invariants + enforcement pointers

Wrangle's reusable workflows run with the base repo's secrets and privileges.
The threat that matters here is **adopter trigger misconfiguration**: wiring a
reusable workflow under a GitHub Actions trigger that runs attacker-influenced
code in that privileged context (the "pwn request" class — base-repo secrets +
a checkout of PR-author code; cf. the TanStack/router Mini Shai-Hulud
compromise, May 2026).

The defense is one composite action, [`actions/preflight_guard`](../../actions/preflight_guard/action.yml),
run as the first job (`guard:`) of every reusable workflow. It refuses unsafe
triggers by failing (`exit 1`); every other job declares `needs: [guard]`, so a
refused invocation skips the whole run — no OIDC tokens, no publish, no
provenance.

### Contract (adopter- and maintainer-facing; stable)

| | |
|---|---|
| **Location** | `actions/preflight_guard/{action.yml,preflight_guard.sh}` |
| **Input** | env only: `EVENT_NAME` (`github.event_name`), `OUTER_EVENT` (`github.event.workflow_run.event`) — no interpolation into the shell body |
| **Exit 0** | trigger allowed |
| **Exit 1** | trigger refused — fails the workflow |

**Designed-for triggers (allowed):** `push` (main, release branches, tags,
`integration/**`), `workflow_dispatch`, `workflow_call`, `workflow_run`
triggered by `push`.

### Invariants

Each invariant ends in the test that enforces it, or `⚠ prose load-bearing`
where nothing mechanical does.

- **Refuses `pull_request_target`** — the direct pwn-request vector: base-repo
  secrets while a checkout pulls PR-author code. → `actions/preflight_guard/test.bats`
  "behavior: refuses pull_request_target".
- **Refuses `workflow_run` triggered by `pull_request_target`** — the indirect
  form; the **outer** event (`OUTER_EVENT`), not just `EVENT_NAME`, is checked.
  → `actions/preflight_guard/test.bats` "behavior: refuses workflow_run
  triggered by pull_request_target"; the non-refused twin is "behavior: allows
  workflow_run triggered by push (not pull_request_target)".
- **Fail-closed via `needs: [guard]`** — a refusal must skip every downstream
  job; a green ✅ with everything skipped would hide the misconfiguration, so
  fail-loud is the security-relevant property. → `test/test_refuse_pull_request_target.bats`
  "wiring: every non-guard job lists guard in its needs"; "wiring: first job in
  each reusable workflow is guard"; "wiring: guard job invokes
  actions/preflight_guard via uses:".
- **Guard runs unprivileged** — the `guard:` job has `permissions: {}`, so the
  refusal check itself holds no token. → `test/test_refuse_pull_request_target.bats`
  "wiring: guard job has permissions: {}".
- **No expression injection** — `EVENT_NAME`/`OUTER_EVENT` reach the script
  through `env:`, never interpolated into the `run:` body. → `actions/preflight_guard/test.bats`
  "structure: action.yml passes env vars (no expression interpolation into
  shell body)".
- **Guard is not a no-op** — the refusal message keeps the pwn-request
  fingerprint, breaking loudly if the guard is swapped for a stub. →
  `actions/preflight_guard/test.bats` "structure: error message references the
  pwn-request vector".

### `_guard` vs. `_gate` — the suffix is the contract

Two preflight check shapes sit at workflow start; downstream gates on them
differently.

| | `actions/preflight_guard` | `actions/release_gate` |
|---|---|---|
| **What it does** | Refuses an unsafe trigger | Decides if release-time jobs run this event/ref |
| **Mechanism** | `exit 1` | output `should-release=true|false` |
| **Downstream** | `needs: [guard]` — fail propagation | `if: needs.gate.outputs.should-release == 'true'` — branch |
| **On a "no"** | Whole workflow fails; everything skips | Workflow succeeds; build/test still run, publish/provenance skip |

`_guard` = abort on fail (a misconfiguration must be loud). `_gate` = signal and
let downstream branch (legit non-release events still build/test). The suffix is
load-bearing: it tells a downstream job which shape to wire. → ⚠ prose
load-bearing — no test asserts the suffix-to-behavior mapping; `release_gate`'s
signal shape is covered by `test/test_release_gate.bats`, but nothing links the
naming convention to the mechanism.

### Out of scope (guard does NOT refuse — adopter responsibility)

- `pull_request` from a fork then `checkout`-ing the head SHA — same untrusted
  checkout, but no base-repo privileges, so smaller blast radius. `actions/scan`'s
  zizmor flags this for adopters in the source-scan path.
- `workflow_dispatch` chains seeded by an upstream `pull_request_target` —
  GitHub flattens the chain to `workflow_dispatch`; the guard sees only that.
  The `workflow_run`-via-`pull_request_target` check covers the common indirect
  vector. → ⚠ prose load-bearing — by design, no enforcement.

### Adding a refusal category

Add the check to `actions/preflight_guard/preflight_guard.sh`, add a row to the
refuses list above, and add a `behavior:` assertion to
`actions/preflight_guard/test.bats`. → ⚠ prose load-bearing — process rule, not
mechanically enforced.

### DRIFT

- **Self-reference anchor.** `preflight_guard.sh` and `action.yml` point
  adopters at `docs/SPEC.md#trigger-model` (asserted by `actions/preflight_guard/test.bats`
  "structure: error message points adopters at docs/SPEC.md#trigger-model"). If
  this contract becomes the source of truth, those references and that test must
  move to `docs/contracts/triggers.md` in the same change, or the on-failure
  message sends adopters to a stale section.
