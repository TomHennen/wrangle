# Dependency Review — Tool Specification

| Property | Value |
|----------|-------|
| Pattern | Action (wraps `actions/dependency-review-action`) |
| Trigger | `pull_request` events only — upstream action needs `github.event.pull_request.base.sha` / `head.sha` to compute the diff |
| Configuration | `fail-on-severity` (default `high`) and `comment-summary-in-pr` (default `never`, to avoid requiring `pull-requests: write`) are inputs on this wrapper action. `actions/scan` and `check_source_change.yml` do **not** forward them — per-tool configuration is deferred to the native config-file design in [#221](https://github.com/TomHennen/wrangle/issues/221). Callers invoking `tools/dependency-review` directly can still set them. |
| SARIF output | `collect_outputs.sh` reads dep-review's `vulnerable-changes` JSON from the `VULNERABLE_CHANGES` env var, calls `vulnerable_changes_to_sarif.sh`, and atomically writes `$WRANGLE_METADATA_DIR/dependency-review/output.sarif` (plus `output.md`) |
| Human-readable output | `output.md` generated from SARIF via `lib/sarif_to_md.sh` for step summary details |
| SARIF upload | Handled by the scan composite via `github/codeql-action/upload-sarif` (category `wrangle/dependency-review`) |
| Default policy | `:fail` — newly-introduced vulnerable deps block the PR |
| Required permissions | `contents: read` (already standard for `actions/checkout`); no extra perms unless `comment-summary-in-pr` is overridden to `on-failure` or `always`, in which case the adopter must also grant `pull-requests: write` |
| Skipped on | Any event other than `pull_request` — the upstream action errors out without the diff base/head refs. On those events the metadata directory is not produced, and `lib/check_results.sh` treats the missing SARIF as "tool did not run", matching the Scorecard pattern |

`lib/check_results.sh` is the pass/fail gate **only on `pull_request` events**, where the SARIF is produced. On any other event the tool is skipped entirely, no SARIF is written, and `check_results.sh` continues silently for this tool — the same contract as Scorecard.

## How dep-review complements OSV-Scanner

OSV scans the entire lockfile on every event and reports any known vulnerability. Dep-review scans **just the diff** on PRs and (by default) blocks the merge. They overlap at the package level but differ in trigger and intent:

- OSV is the periodic / push-time view: "what is currently in the lockfile?"
- Dep-review is the PR-time gate: "is this PR introducing something known-vulnerable?"

A package already in the lockfile with a known vulnerability shows up in OSV but not dep-review (dep-review only flags newly-added or upgraded entries). A package introduced in a PR shows up in both. This is intentional — the PR is exactly when blocking is least disruptive.

## SARIF conversion

`actions/dependency-review-action` does not emit SARIF natively. Its `vulnerable-changes` output is a JSON array of dependency changes with embedded `vulnerabilities` arrays. The wrangle wrapper converts each `(change, vulnerability)` pair to one SARIF result and each unique GHSA id to one SARIF rule, so the existing per-tool SARIF upload to GitHub Code Scanning works unchanged.

Severity mapping:

| dep-review severity | SARIF level | security-severity |
|---------------------|-------------|-------------------|
| critical | error | 9.5 |
| high | error | 7.5 |
| moderate | warning | 5.0 |
| low | note | 2.5 |

With the default `fail-on-severity: high`, the upstream action only emits `high` / `critical` advisories, so in practice only the `error`-level rows occur; the `moderate` / `low` rows apply when an adopter lowers `fail-on-severity`. Either way, every advisory that reaches the converter blocks the PR — the SARIF `level` affects only how the GitHub Security tab renders a finding, not the `check_results.sh` gate.

Every change except `change_type: "removed"` is converted — a `"removed"` entry means the PR drops a vulnerable dependency, which must not block the PR. The filter tests `!= "removed"` rather than `== "added"` so it fails safe: `change_type` is currently a two-value enum (`added`, `removed`), but if the upstream schema ever gains a new value, a vulnerable change of that type is still surfaced rather than silently dropped.

A vulnerable change is converted regardless of its `scope` — a vulnerable `development`/build-time dependency is flagged exactly like a `runtime` one. That is deliberate and matches the default policy of blocking on any introduced vulnerability; scope-aware policy (à la dependency-review-action's `fail-on-scopes`) would belong with the per-tool configuration design in [#221](https://github.com/TomHennen/wrangle/issues/221).

## Tool-error handling

`continue-on-error: true` on the upstream step is required so the SARIF collection step runs even when dep-review exits non-zero on findings. `lib/check_results.sh` is the actual pass/fail gate via the produced SARIF.

A tool error (Dependency Review API unavailable, Dependency Graph disabled, network failure) also surfaces as a non-zero upstream exit but with an empty `vulnerable-changes` output. The wrapper distinguishes the two cases:

- Non-zero exit with a non-empty `vulnerable-changes` array → findings → SARIF contains the entries → `check_results.sh` fails on the SARIF count.
- Non-zero exit with empty/`[]` `vulnerable-changes` → tool error → `mark_error.sh` writes an `error` marker into the metadata directory → `check_results.sh` fails closed on the marker (issue [#222](https://github.com/TomHennen/wrangle/issues/222)).

## Known limitations

- License-policy findings (`invalid-license-changes`) and denied-package findings (`denied-changes`) are **not** currently converted to SARIF. Only `vulnerable-changes` flow into `output.sarif`. Adopters relying on license / deny-list policies should rely on the upstream action's own failure exit code; the wrangle wrapper preserves that exit semantics via `lib/check_results.sh` only for vulnerability findings.
- The upstream action calls the GitHub Dependency Review API, which requires the PR's diff to be reachable. Forks of repositories that disable the GitHub Dependency Graph will not get useful output, but the error marker above ensures this fails closed rather than fails open.
