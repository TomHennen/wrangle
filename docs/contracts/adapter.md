# Adapter Script Interface

Each scan tool in the **adapter** pattern ships a `tools/<name>/adapter.sh` that
wraps the underlying scanner in a standard interface. The orchestrator
(`run.sh`) invokes it with a read-only source tree and a writable output dir,
then collects `output.sarif`; users never call it directly.

## Contract

| | |
|---|---|
| **Location** | `tools/<name>/adapter.sh` |
| **Usage** | `adapter.sh <src_dir> <output_dir>` |
| **Inputs** | `src_dir` — source to scan (read-only); `output_dir` — results dir (writable, already exists) |
| **Outputs** | `output.sarif` (REQUIRED, SARIF 2.1.0); `output.md` / `output.txt` (OPTIONAL human-readable summary) |
| **Exit 0** | scan completed, no findings |
| **Exit 1** | scan completed, findings detected |
| **Exit 2** | scan failed (tool error) or usage/argument error |

**Preconditions:** the tool binary and `jq` are on `$PATH` (the install script
places the binary).

**Output fallback:** if the adapter writes neither `output.md` nor `output.txt`,
the orchestrator generates `output.md` from `output.sarif` via
`lib/sarif_to_md.sh`. Adapters with richer tool-specific output should write
their own `output.md` to pre-empt this fallback.

**Restricted environment / `WRANGLE_EXTRA_`:** adapters run with a stripped env —
only `PATH`, `HOME`, `TMPDIR`, `RUNNER_TEMP`, `GITHUB_WORKSPACE`, and
`GITHUB_STEP_SUMMARY` pass through. Secrets (`GITHUB_TOKEN`,
`ACTIONS_RUNTIME_TOKEN`, …) are not. A tool needing an extra variable (e.g. a
private vuln-DB token) sets it in the composite action's `env:` with a
`WRANGLE_EXTRA_` prefix; the orchestrator forwards any `WRANGLE_EXTRA_*` to the
adapter with the prefix stripped (`WRANGLE_EXTRA_OSV_DB_TOKEN` → `OSV_DB_TOKEN`).

## Invariants

Each invariant is followed by the check that enforces it, or `⚠ prose
load-bearing` where nothing mechanical does yet.

- **Exit-code semantics** — 0 / 1 / 2 mean no-findings / findings / tool-error
  respectively. → `tools/osv/test.bats` "osv adapter: produces SARIF with no
  findings (exit 0)", "osv adapter: produces SARIF with findings (exit 1)",
  "osv adapter: tool error produces exit 2".
- **Required SARIF output** — a successful (0/1) run writes `output.sarif`. →
  `tools/osv/test.bats` "osv adapter: produces SARIF with no findings (exit 0)"
  and "...with findings (exit 1)" (both assert `output.sarif` exists).
- **Malformed SARIF → exit 2** — `jq` exit codes are checked; unparseable
  scanner output fails the adapter rather than passing silently. → 
  `tools/osv/test.bats` "osv adapter: invalid JSON SARIF produces exit 2".
- **Argument / precondition validation** — wrong arg count, or a missing
  `src_dir` / `output_dir`, exits 2 with usage. → `tools/osv/test.bats` "osv
  adapter: requires 2 arguments", "osv adapter: fails if src_dir does not
  exist", "osv adapter: fails if output_dir does not exist".
- **Output-fallback wiring** — when the adapter emits no `output.md`, the
  orchestrator renders one from the SARIF. The renderer itself is tested
  (`test/test_sarif_to_md.bats`), but `run.sh`'s invocation of it
  (`run.sh:177-180`) has no direct test. → ⚠ prose load-bearing (wiring); helper
  covered by `test/test_sarif_to_md.bats`.
- **`output.sarif` is valid SARIF 2.1.0** — only validity-as-JSON (`jq empty`)
  and result counts are checked; no full JSON-Schema conformance check runs. The
  `test/test_sarif_schema.bats` header claims schema validation "is done in CI",
  but no workflow wires a validator, and that suite only validates *fixtures*,
  not adapter output. → ⚠ prose load-bearing (SARIF *2.1.0* conformance); JSON
  validity covered by `tools/osv/test.bats` "osv adapter: produces SARIF with no
  findings (exit 0)".

### Security invariants

- **Stripped environment / no secrets** — the orchestrator removes secrets
  before invoking the adapter; `WRANGLE_EXTRA_*` is the only escape hatch. →
  `test/test_orchestrator.bats` "orchestrator: strips GITHUB_TOKEN from adapter
  environment", "orchestrator: forwards WRANGLE_EXTRA_ vars with prefix
  stripped", "orchestrator: PATH is available to adapter".
- **No writes outside `output_dir`** — enforced *softly*: the orchestrator runs a
  post-execution filesystem check and **warns** (does not fail — exit stays 0) on
  modifications outside `output_dir`. The adapter's own discipline still carries
  the hard guarantee. → partial: `test/test_orchestrator.bats` "orchestrator:
  detects filesystem modifications outside output_dir" (asserts status 0 +
  WARNING).
- **No network beyond the tool's own scan needs** — nothing isolates the
  adapter's network (no `unshare`/firewall); this is honored by tool choice
  alone. → ⚠ prose load-bearing.
- **Sanitized `GITHUB_STEP_SUMMARY`** — `GITHUB_STEP_SUMMARY` is exposed to
  adapters, so anything an adapter writes there must be HTML/markdown-sanitized;
  no test covers an adapter doing so. The orchestrator's *own* summary-rendering
  path is separately sanitized (`lib/sanitize.sh`, tested by
  `test/test_sanitized_summary.bats`), but that is a different actor. → ⚠ prose
  load-bearing (the adapter-side obligation).

## Scope note (coverage floor)

Only `tools/osv/` exercises this contract today — which is why nearly every
pointer above lands on `tools/osv/test.bats`. `dependency-review` and
`scorecard` are **action-pattern** tools: their tests explicitly assert *no*
`adapter.sh` exists (`tools/dependency-review/test.bats` "dependency-review: no
adapter.sh exists (action pattern, not adapter)"; `tools/scorecard/test.bats`
"scorecard: no adapter.sh exists (action pattern, not adapter)"). The adapter
contract therefore has a coverage floor of exactly one tool.
