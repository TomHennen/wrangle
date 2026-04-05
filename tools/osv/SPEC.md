# OSV-Scanner — Tool Specification

| Property | Value |
|----------|-------|
| Pattern | Adapter (`tools/osv/install.sh` + `tools/osv/adapter.sh`) |
| Integrity verification | SLSA provenance via `slsa-verifier` |
| SARIF output | `$WRANGLE_METADATA_DIR/osv/output.sarif` (written by adapter) |
| SARIF upload | Wrangle uploads with category `wrangle/osv` |
| Default policy | `:fail` — dependency vulnerabilities block the check |
| Known limitations | Exit code 128 (no package sources found) produces empty SARIF, not an error |
