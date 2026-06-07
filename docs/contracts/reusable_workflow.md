# Reusable Workflow Interface

The reusable workflow (`.github/workflows/check_source_change.yml`) wraps the
scan composite action for `workflow_call` consumers. An adopter adds one small
workflow file to their repo and gets source scanning with no secrets and nothing
to maintain. This file is the readable copy-paste reference — adopters never read
the bats tests.

## Contract

| | |
|---|---|
| **Location** | `.github/workflows/check_source_change.yml` |
| **Trigger** | `workflow_call` |
| **Input** | `tools` — `type: string`, space-separated `name[:fail|:info]` list; `required: false` |
| **Default** | `osv zizmor scorecard:info dependency-review` |
| **Secrets** | none |
| **Caller permissions** | `actions: read`, `contents: read`, `security-events: write` (SARIF upload) |

The `tools` string syntax (`:fail` default / `:info` informational) is identical
to the composite action's — see
[`composite_action.md`](composite_action.md#tools-string-syntax). The workflow
forwards `tools` straight through to `actions/scan`.

### Adopter workflow (the entire file an adopter adds)

> **Make this drift-proof.** The canonical copy of this snippet is the Quick
> Start block in the repo `README.md` (lines 9–24). Rather than maintaining a
> third hand-copy here, this example should be lifted from — or CI-diffed against
> — that README block (or a designated `examples/` file if one is created) so the
> three copies cannot diverge. Until that check exists, treat the snippet as
> illustrative.

```yaml
name: Check Source Change
on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["**"]

jobs:
  check-change:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@v0.1.0
```

## Invariants

Each invariant is followed by the check that enforces it, or `⚠ prose
load-bearing` where nothing mechanical does yet.

- **Trigger guard runs first and gates everything** — the workflow's first job is
  `guard`, which refuses supply-chain-dangerous triggers
  (`pull_request_target`, `workflow_run` off `pull_request_target`); every other
  job lists `guard` in its `needs:`, so a refused invocation skips the whole
  workflow. → *wiring:* `test/test_refuse_pull_request_target.bats` "wiring: first
  job in each reusable workflow is guard", "wiring: every non-guard job lists
  guard in its needs"; *refusal behavior:* `actions/preflight_guard/test.bats`
  "behavior: refuses pull_request_target", "behavior: refuses workflow_run
  triggered by pull_request_target", "behavior: allows push".
- **Guard holds no permissions** — the guard job runs with `permissions: {}`
  (reads event context only — no workspace, API, or secrets). →
  `test/test_refuse_pull_request_target.bats` "wiring: guard job has
  permissions: {}".
- **`tools` forwarded unchanged to the scan action** — the workflow passes its
  `tools` input through to `actions/scan`; all `tools`-string semantics
  (suffixes, validation, policy) are the composite action's contract. → ⚠ prose
  load-bearing (the pass-through wiring); downstream behavior covered by
  `test/test_orchestrator.bats` and `test/test_check_results.bats` (see
  `composite_action.md`).

### Security invariants

- **No expression injection** — `inputs.tools` reaches the scan action via a
  `with:` mapping, not via interpolation into a `run:` body. → workflow-lint
  **WWL002** (`tools/wrangle-workflow-lint/`), "WWL002: inputs.* interpolated
  into a run body is reported".
