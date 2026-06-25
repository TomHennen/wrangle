# Zizmor — Tool Specification

| Property | Value |
|----------|-------|
| Pattern | Action (wraps `zizmorcore/zizmor-action`); also delivered as a contract image (catalog `delivery: image`) for the `run.sh` docker path |
| Configuration | `advanced-security: true` — upstream action produces SARIF and uploads to Security tab |
| SARIF output | Upstream action writes SARIF; wrangle copies to `$WRANGLE_METADATA_DIR/zizmor/output.sarif` for the summary collector |
| Human-readable output | `output.md` generated from SARIF via `lib/sarif_to_md.sh` for step summary details |
| SARIF upload | Handled by the upstream action (wrangle does not upload separately) |
| Default policy | `:fail` — workflow security issues block the check |
| Suppression | `.zizmor.yml` at repo root configures accepted findings. Suppress only documented false positives, not convenience silencing |
| Tool-error handling | With `advanced-security: true` zizmor runs in SARIF mode and exits 0 regardless of findings, so the upstream step's `failure` outcome means the Code Scanning upload failed (e.g. no Advanced Security) or zizmor itself errored — never a findings signal. `continue-on-error: true` keeps that non-zero outcome from failing the job, so the SARIF collection step runs and `lib/check_results.sh` stays the single gate. `collect_sarif.sh` disambiguates "found issues" from "tool error": only a missing, empty, or malformed SARIF under outcome `failure` writes an `error` marker that `check_results.sh` reads to fail closed for `:fail` policy. A parseable SARIF is authoritative — `>0` results are preserved as findings, and zero results is a clean audit even when the outcome is `failure` (the upload, run after the SARIF is written, is what failed). The "Check results" step in the scan action is the actual pass/fail gate. |

## Install paths

Zizmor has two install paths and they are kept deliberately in sync:

1. **CI (adopter-facing)** — `actions/scan/action.yml` invokes `tools/zizmor/action.yml`, which wraps the upstream `zizmorcore/zizmor-action`. That upstream action handles fetching and verifying the binary in the workflow runner.
2. **Local test container** — `test/Dockerfile` installs zizmor via `pip --require-hashes` into a managed venv from `tools/zizmor/requirements.txt`, which hash-pins zizmor and is updated by Dependabot (pip ecosystem; see `.github/dependabot.yml`). Pip refuses any artifact whose sha256 isn't in the file — version and hashes always move together. `make zizmor` (and the default `./test.sh`) runs this copy against the wrangle repo so workflow security findings surface in the same `make test` loop as shellcheck and actionlint, not only in CI.

`tools/zizmor/action.yml`'s default `version` input and `tools/zizmor/requirements.txt`'s `zizmor==` pin must track each other; a structural test in `test.bats` enforces this. Bumping one without the other masks regressions between the local pre-push check and CI.

## Detection canary

`test.bats` runs the real binary against `fixtures/unpinned_uses.yml` — a deliberately tag-pinned action — and asserts the `unpinned-uses` audit still fires. The rest of the suite feeds synthetic SARIF, which proves the plumbing but never that zizmor still *detects* anything; the canary is the positive control that turns a false-negative regression (a zizmor version or config change that silently stops flagging a class) into a red test instead of a passing scan.

