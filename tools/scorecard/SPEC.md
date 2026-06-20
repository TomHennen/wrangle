# OSSF Scorecard — Tool Specification

| Property | Value |
|----------|-------|
| Pattern | Action (wraps `ossf/scorecard-action`) |
| JSON output | `$WRANGLE_METADATA_DIR/scorecard/output.json` (workspace-relative path required — Scorecard runs inside Docker, which mounts `$GITHUB_WORKSPACE` but not `$RUNNER_TEMP`) |
| Attestation | `https://scorecard.dev/result/v0.1` (passthrough — `output.json` is the predicate; manifest dropped via `lib/write_attest_manifest.sh`, signed in the trusted verify job by `wrangle-attest`) |
| Human-readable output | `output.md` via `json_to_markdown.sh` (aggregate score + per-check table for step summary details) |
| Security tab | None — Scorecard does not upload SARIF (informational-only, cf #203). Its value is the score, carried by the attestation, not per-finding SARIF. |
| Default policy | `:info` — does not fail the check |
| Event restriction | Skipped on `pull_request` events. Scorecard requires `GITHUB_TOKEN` scopes only available on default branch pushes. |
| Known limitations | `publish_results: false` — wrangle does not publish to the public Scorecard registry. `continue-on-error: true` on the upstream step because Scorecard may fail for token/permission reasons outside wrangle's control; the manifest is dropped only when `output.json` exists, so a failed run attests nothing. |

## Why JSON, not SARIF

Scorecard's value is the aggregate **score**, which appears only in `--format=json`, not in its SARIF. Scorecard runs once as `--format=json`; that JSON is attested verbatim as the `scorecard.dev/result/v0.1` predicate so a downstream policy can gate on `score >= N` (#497). `--format=intoto` is not used — it would emit a full in-toto Statement and double-wrap the engine's own statement.

## Why informational-only

Scorecard assesses repo-level security posture (branch protection, dependency update practices, etc.), not per-change vulnerabilities. A low score is a maintenance signal, not a reason to block a PR. Adopters can override this by using `scorecard:fail` in the tools input; score-threshold gating itself is the tenet-activation work (#497).

## Docker mount constraint

Scorecard's upstream action runs inside a Docker container that only mounts `$GITHUB_WORKSPACE`. This is why the metadata directory must be workspace-relative — paths under `$RUNNER_TEMP` are not accessible inside the container.
