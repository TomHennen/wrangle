# OSSF Scorecard — Tool Specification

| Property | Value |
|----------|-------|
| Pattern | Action (wraps `ossf/scorecard-action`) |
| SARIF output | `$WRANGLE_METADATA_DIR/scorecard/output.sarif` (workspace-relative path required — Scorecard runs inside Docker, which mounts `$GITHUB_WORKSPACE` but not `$RUNNER_TEMP`) |
| Human-readable output | `output.md` via `sarif_to_markdown.sh` (Scorecard-specific markdown table for step summary details) |
| SARIF upload | Wrangle uploads with category `wrangle/scorecard` (push events only) |
| Default policy | `:info` — does not fail the check |
| Event restriction | Skipped on `pull_request` events. Scorecard requires `GITHUB_TOKEN` scopes only available on default branch pushes. |
| Known limitations | `publish_results: false` because wrangle controls SARIF upload separately. `continue-on-error: true` on the upstream step because Scorecard may fail for token/permission reasons outside wrangle's control. |

## Why informational-only

Scorecard assesses repo-level security posture (branch protection, dependency update practices, etc.), not per-change vulnerabilities. A low score is a maintenance signal, not a reason to block a PR. Adopters can override this by using `scorecard:fail` in the tools input.

## Docker mount constraint

Scorecard's upstream action runs inside a Docker container that only mounts `$GITHUB_WORKSPACE`. This is why the metadata directory must be workspace-relative — paths under `$RUNNER_TEMP` are not accessible inside the container.
