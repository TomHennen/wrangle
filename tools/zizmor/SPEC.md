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
| Known limitations | `continue-on-error: true` on the upstream step is required so the SARIF collection step can access outputs after zizmor finds issues (exit code 14). The "Check results" step in the scan action is the actual pass/fail gate. |

## Install paths

Zizmor has two install paths and they are kept deliberately in sync:

1. **CI (adopter-facing)** — `actions/scan/action.yml` invokes `tools/zizmor/action.yml`, which wraps the upstream `zizmorcore/zizmor-action`. That upstream action handles fetching and verifying the binary in the workflow runner.
2. **Local test container** — `test/Dockerfile` installs zizmor directly from the upstream GitHub release using a pinned `ZIZMOR_VERSION` and per-arch sha256 checksums, mirroring the actionlint install layer. `make zizmor` (and the default `./test.sh`) runs this copy against the wrangle repo so workflow security findings surface in the same `make test` loop as shellcheck and actionlint, not only in CI.

Versions in both paths should track each other; bumping one without the other masks regressions between the local pre-push check and CI.

