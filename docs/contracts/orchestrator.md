# Orchestrator Interface

`run.sh` (at the repo root) installs and runs multiple scan adapters in one
pass, then prints a summary. It is invoked by the scan composite action, not by
users directly. For each tool spec it validates the name, installs the tool,
runs its adapter in a stripped environment, and records pass/fail.

## Contract (adopter- and maintainer-facing; stable)

| | |
|---|---|
| **Location** | `run.sh` (repo root) |
| **Usage** | `run.sh [-s <src_dir>] [-o <output_dir>] <tool1> [tool2] ...` |
| **Inputs** | `-s` source dir to scan (default `.`); `-o` output dir (default `./metadata`); one or more tool specs (`osv`, `scorecard:info`, …) — an optional `:fail`/`:info` policy suffix is stripped and ignored here |
| **Outputs** | `<output_dir>/<tool>/` per tool (adapter writes `output.sarif` inside it); a summary table on stdout |
| **Exit 0** | all tools passed, no findings |
| **Exit 1** | at least one tool found issues |
| **Exit 2** | at least one tool failed to run (includes invalid tool names and timeouts) |

## Invariants

Each invariant is followed by the check that enforces it, or `⚠ prose
load-bearing` where nothing mechanical does yet.

- **Strict tool-name allowlist** — every spec must match `^[a-z][a-z0-9_-]*$`
  after the policy suffix is stripped; this is the single barrier against path
  traversal, shell injection, and glob/word-splitting, because the name flows
  into both a filesystem path and a command. → `test/test_orchestrator.bats`
  "rejects tool name with path traversal", "rejects tool name with semicolon",
  "rejects tool name with uppercase", "rejects tool name starting with number",
  "accepts valid tool names".
- **Unknown tools are rejected, action-pattern tools are skipped** — a spec with
  no `tools/<tool>/` directory is a hard error (exit 2); a directory that exists
  but has no `adapter.sh`/`install.sh` is an action-pattern tool handled by the
  scan action's `uses:` steps, and is silently skipped. → `test/test_orchestrator.bats`
  "rejects unknown tool (no directory)", "skips action-pattern tool (directory
  exists, no adapter.sh)", "skips action-pattern tools in mixed list".
- **Policy suffix is stripped, not consumed** — `:fail`/`:info` is removed before
  any processing; the orchestrator never reads policy (that is the scan action's
  `lib/check_results.sh`). → `test/test_orchestrator.bats` "strips policy suffix
  from tool names".
- **Exit codes aggregate, error wins** — 0/1/2 map to clean/findings/failure, and
  a single failing tool dominates a findings tool in the final code. →
  `test/test_orchestrator.bats` "runs clean tool (exit 0)", "runs findings tool
  (exit 1)", "runs error tool (exit 2)", "handles install failure (exit 2)",
  "error takes precedence over findings".
- **Bounded execution** — install and adapter invocations are each wrapped in
  `timeout(1)` so a hung tool cannot consume the whole job (GitHub Actions
  default 6h); a timeout is reported as tool failure (exit 2) and the run
  continues to the next tool. Defaults are 300s (install) and 600s (adapter),
  overridable via `WRANGLE_INSTALL_TIMEOUT`/`WRANGLE_ADAPTER_TIMEOUT`. →
  `test/test_orchestrator.bats` "adapter timeout produces exit 2", "install
  timeout produces exit 2".
- **Adapter runs in a deny-all environment** — adapters are launched with
  `env -i` and an explicit allowlist (`PATH`, `HOME`, `TMPDIR`, `RUNNER_TEMP`,
  `GITHUB_WORKSPACE`, `GITHUB_STEP_SUMMARY`) plus `WRANGLE_EXTRA_*` vars with the
  prefix stripped; everything else, including `GITHUB_TOKEN`, is absent. This is
  the load-bearing secrets boundary — an untrusted scanner never sees CI
  credentials. → `test/test_orchestrator.bats` "strips GITHUB_TOKEN from adapter
  environment", "forwards WRANGLE_EXTRA_ vars with prefix stripped", "PATH is
  available to adapter".
- **Out-of-sandbox writes are detected** — the orchestrator snapshots the
  filesystem around each adapter and warns when an adapter modifies anything
  outside its `output_dir`. → `test/test_orchestrator.bats` "detects filesystem
  modifications outside output_dir". (Detection only — a stray write warns, it
  does not fail the run. ⚠ prose load-bearing for the fail-vs-warn policy.)
- **Path resolution is script-relative** — install/adapter paths are resolved
  from `BASH_SOURCE` (`SCRIPT_DIR`), never `$PWD`, so the orchestrator works when
  invoked via `github.action_path` from an adopter's checkout. →
  `test/test_orchestrator.bats` "resolves tool paths relative to script, not
  cwd".
- **No tools is a usage error** — invoking with zero specs prints usage rather
  than silently succeeding. → `test/test_orchestrator.bats` "no tools provided
  prints usage".

## Notes

- **Env isolation is deny-all, then allow.** `run.sh` uses `env -i` to clear the
  entire environment and re-adds only `PATH`, `HOME`, `TMPDIR`, `RUNNER_TEMP`,
  `GITHUB_WORKSPACE`, `GITHUB_STEP_SUMMARY`, plus any `WRANGLE_EXTRA_*`. A new
  variable an adapter needs must join that allowlist or arrive via
  `WRANGLE_EXTRA_`.
- **Timeouts are configurable.** The 5-minute install / 10-minute adapter
  defaults are overridable via `WRANGLE_INSTALL_TIMEOUT` /
  `WRANGLE_ADAPTER_TIMEOUT`.
- **Out-of-sandbox writes are detected, not blocked.** The post-adapter
  filesystem check warns on modifications outside `output_dir` but does not fail
  the run. The hard boundary is adapter discipline.
- **Validation lives in `run.sh`, not the shared libs.** Tool names are validated
  by `run.sh`'s inline `TOOL_NAME_RE`; `lib/validate_path.sh` (build actions'
  `inputs.path`) and `lib/sanitize.sh` (summary HTML stripping) are different
  actors, not part of this interface.
