# Zizmor — Tool Specification

| Property | Value |
|----------|-------|
| Pattern | Action (wraps `zizmorcore/zizmor-action`) |
| Configuration | `advanced-security: true` — upstream action produces SARIF and uploads to Security tab |
| SARIF output | Upstream action writes SARIF; wrangle copies to `$WRANGLE_METADATA_DIR/zizmor/output.sarif` for the summary collector |
| SARIF upload | Handled by the upstream action (wrangle does not upload separately) |
| Default policy | `:fail` — workflow security issues block the check |
| Suppression | `.zizmor.yml` at repo root configures accepted findings. Suppress only documented false positives, not convenience silencing |
| Known limitations | `continue-on-error: true` on the upstream step is required so the SARIF collection step can access outputs after zizmor finds issues (exit code 14). The "Check results" step in the scan action is the actual pass/fail gate. |
