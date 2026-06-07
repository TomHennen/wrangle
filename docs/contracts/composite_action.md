# Composite Action Interface

The scan action (`actions/scan/action.yml`) is the primary GitHub Actions entry
point. Adopters reference it (directly or through the reusable workflow), pass a
`tools` string, and get source scanning with a step-summary report. This file is
the readable copy-paste reference — adopters never read the bats tests.

## Contract

| | |
|---|---|
| **Location** | `actions/scan/action.yml` (composite action) |
| **Input** | `tools` — space-separated list, each `name[:fail|:info]`; `required: false` |
| **Default** | `osv zizmor scorecard:info dependency-review` |
| **Secrets** | none — tools are downloaded as public binaries |
| **Primary output** | a markdown report appended to `$GITHUB_STEP_SUMMARY` (works on every repo, including private / no-Advanced-Security) |
| **Additive outputs** | SARIF uploaded to GitHub Code Scanning (optional — absent on repos without Advanced Security); a `wrangle-scan-results` artifact; the metadata dir `$GITHUB_WORKSPACE/.wrangle/metadata/` cataloguing which tools ran and what they found |
| **Failure** | the check fails if any `:fail`-policy tool reported findings; `:info` tools are noted but never block |

### `tools` string syntax

Each token is a tool name with an optional policy suffix:

- `name` or `name:fail` — **default.** Findings from the tool fail the check
  (non-zero exit).
- `name:info` — informational. Findings are listed in the summary but do not
  block. Useful for posture tools like Scorecard that assess repo-level health
  rather than per-change vulnerabilities.

Adopters override the default per tool, e.g. `scorecard:fail` to enforce
Scorecard scores, or `osv zizmor` to drop Scorecard entirely.

The action splits `tools` into **adapter-pattern** tools (those with
`tools/<name>/adapter.sh`, dispatched to the orchestrator `run.sh`) and
**action-pattern** tools (invoked via their own `uses:` steps, gated on the tool
name appearing in `tools`). Suffixes are stripped before tool names reach the
orchestrator; the full `name:policy` list is passed to `lib/check_results.sh`
for evaluation.

### Usage example

> **Make this drift-proof.** The real wiring lives in `actions/scan/action.yml`.
> Rather than hand-copying the snippet below (which is what produced the drift
> bugs noted at the bottom of this file), the example should be lifted from — or
> CI-diffed against — `actions/scan/action.yml` so it cannot silently fall out of
> sync. Until that check exists, treat the snippet as illustrative, not
> authoritative.

```yaml
# from actions/scan/action.yml — adapter-pattern dispatch
- name: Run adapter-pattern tools
  shell: bash
  env:
    WRANGLE_TOOLS: ${{ inputs.tools }}          # threaded through env:, never interpolated into run:
    WRANGLE_ROOT: ${{ github.action_path }}/../..
  run: |
    source "$WRANGLE_ROOT/lib/env.sh"
    # $WRANGLE_TOOLS is intentionally unquoted so it word-splits into
    # multiple arguments; run.sh validates each token and runs set -f.
    "$WRANGLE_ROOT/run.sh" -s "$GITHUB_WORKSPACE" -o "$WRANGLE_METADATA_DIR" $WRANGLE_TOOLS
```

## Invariants

Each invariant is followed by the check that enforces it, or `⚠ prose
load-bearing` where nothing mechanical does yet.

- **`tools` is split, suffixes stripped, names validated** — adapter-pattern
  tools reach the orchestrator with their `:fail`/`:info` suffix removed, and
  each name must match `^[a-z][a-z0-9_-]*$`. → `test/test_orchestrator.bats`
  "orchestrator: strips policy suffix from tool names", "orchestrator: accepts
  valid tool names", "orchestrator: rejects tool name with uppercase",
  "orchestrator: rejects tool name starting with number".
- **Policy semantics** — `:fail` (default) blocks on findings, `:info` does not,
  an unrecognized policy is rejected, and a tool error on a `:fail` tool fails
  the check. → `test/test_check_results.bats` "check_results: default policy is
  fail", "check_results: :info policy does not fail on findings",
  "check_results: invalid policy causes failure", "check_results: error marker on
  :fail tool exits 1".
- **Action-pattern tools are gated on the tool name** — each `uses:` step runs
  only when its name is in `tools`, so omitting a tool suppresses both its scan
  and its SARIF upload (avoids noisy `::error::` on missing metadata). →
  `actions/scan/test.bats` "scan: osv SARIF upload is gated on osv being in the
  tools input", "scan: dependency-review step is gated on dependency-review being
  in the tools input".
- **Step summary is the primary output** — the report is appended to
  `$GITHUB_STEP_SUMMARY`; SARIF/Code-Scanning upload is additive and tolerated to
  fail (`continue-on-error`) since Advanced Security may be unavailable. →
  ⚠ prose load-bearing (that the summary is *primary* / degrades gracefully);
  upload-step presence and categories are covered by `actions/scan/test.bats`
  "scan: has upload-sarif step for osv", "scan: osv SARIF has correct category
  (wrangle/osv)".

### Security invariants

- **No expression injection** — `inputs.tools` is threaded through `env:`
  (`WRANGLE_TOOLS`) and never interpolated directly into a `run:` body. →
  shell/workflow-lint **WWL002** (`tools/wrangle-workflow-lint/`), "WWL002:
  inputs.* interpolated into a run body is reported" / "WWL002: an input threaded
  through env: is not flagged".
- **Defense in depth on the unquoted expansion** — `$WRANGLE_TOOLS` is left
  unquoted so it word-splits into arguments; this is safe because the
  orchestrator validates each token against `^[a-z][a-z0-9_-]*$` and runs
  `set -f` (no globbing) before processing. → `test/test_orchestrator.bats`
  "orchestrator: rejects tool name with semicolon", "orchestrator: rejects tool
  name with path traversal".

### Structural constraint

- **Path depth is fixed at `actions/scan/`** — the action resolves the
  orchestrator via `${{ github.action_path }}/../..` (two directories up). Moving
  the action to a different depth breaks the relative path for every adopter; a
  layout change must update these paths in the same commit. → ⚠ prose
  load-bearing — no test asserts the action's directory depth.
  (`test/test_orchestrator.bats` "orchestrator: resolves tool paths relative to
  script, not cwd" covers `run.sh`'s own path discipline, **not** the action's
  position in the tree.)
