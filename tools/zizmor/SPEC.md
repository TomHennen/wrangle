# Zizmor — Tool Specification

| Property | Value |
|----------|-------|
| Pattern | Action (wraps `zizmorcore/zizmor-action`) |
| Configuration | `advanced-security: true` — upstream action produces SARIF and uploads to Security tab |
| SARIF output | Upstream action writes SARIF; wrangle copies to `$WRANGLE_METADATA_DIR/zizmor/output.sarif` for the summary collector |
| Human-readable output | `output.md` generated from SARIF via `lib/sarif_to_md.sh` for step summary details |
| SARIF upload | Handled by the upstream action (wrangle does not upload separately) |
| Default policy | `:fail` — workflow security issues block the check |
| Suppression | `.zizmor.yml` at repo root configures accepted findings. Suppress only documented false positives, not convenience silencing |
| Tool-error handling | `continue-on-error: true` on the upstream step is required so the SARIF collection step can access outputs after zizmor finds issues (exit code 14). `collect_sarif.sh` disambiguates "found issues" from "tool error": when upstream outcome is `failure` and the SARIF is missing, empty, malformed, or reports zero results, it writes an `error` marker that `lib/check_results.sh` reads to fail closed for `:fail` policy. A parseable SARIF with `>0` results is preserved as findings so `:info` policy reports findings informationally rather than as an error. The "Check results" step in the scan action is the actual pass/fail gate. |

## Install paths

Zizmor has two install paths and they are kept deliberately in sync:

1. **CI (adopter-facing)** — `actions/scan/action.yml` invokes `tools/zizmor/action.yml`, which wraps the upstream `zizmorcore/zizmor-action`. That upstream action handles fetching and verifying the binary in the workflow runner.
2. **Local test container** — `test/Dockerfile` installs zizmor via `pip --require-hashes` into a managed venv from `tools/zizmor/requirements.txt`, which hash-pins zizmor and is updated by Dependabot (pip ecosystem; see `.github/dependabot.yml`). Pip refuses any artifact whose sha256 isn't in the file — version and hashes always move together. `make zizmor` (and the default `./test.sh`) runs this copy against the wrangle repo so workflow security findings surface in the same `make test` loop as shellcheck and actionlint, not only in CI.

`tools/zizmor/action.yml`'s default `version` input and `tools/zizmor/requirements.txt`'s `zizmor==` pin must track each other; a structural test in `test.bats` enforces this. Bumping one without the other masks regressions between the local pre-push check and CI.

## Detection canary

`test.bats` runs the real binary against `fixtures/unpinned_uses.yml` — a deliberately tag-pinned action — and asserts the `unpinned-uses` audit still fires. The rest of the suite feeds synthetic SARIF, which proves the plumbing but never that zizmor still *detects* anything; the canary is the positive control that turns a false-negative regression (a zizmor version or config change that silently stops flagging a class) into a red test instead of a passing scan.

