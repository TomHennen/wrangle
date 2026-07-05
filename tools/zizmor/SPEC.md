# Zizmor — Tool Specification

| Property | Value |
|----------|-------|
| Pattern | Adapter, delivered as a contract image (catalog `delivery: image`); `adapter.sh` is the image ENTRYPOINT and `run.sh` invokes it via `docker run` |
| Integrity verification | zizmor installed into the image from the hash-pinned `tools/zizmor/requirements.txt` (`pip --require-hashes`, the canonical PyPI distribution — keeps the dependency manifest in-repo for Dependabot/osv) |
| SARIF output | `adapter.sh` runs `zizmor --format sarif` and writes `$WRANGLE_METADATA_DIR/zizmor/output.sarif` |
| Human-readable output | `output.md` generated from SARIF via `lib/sarif_to_md.sh` for step summary details |
| SARIF upload | Wrangle uploads with category `wrangle/zizmor` |
| Network / secret | `network: egress` + `secret: github-token` — zizmor reads `GITHUB_TOKEN` for its online audits; `run.sh` injects the catalog secret as `GITHUB_TOKEN`. An absent token leaves online audits skipped, still a valid offline run. |
| Default policy | `:fail` — workflow security issues block the check |
| Suppression | `.zizmor.yml` at repo root configures accepted findings. Suppress only documented false positives, not convenience silencing |
| Tool-error handling | In SARIF mode zizmor exits 0 regardless of findings (they live in the document), so `adapter.sh` derives the findings/no-findings split from the SARIF result count, not the exit code. Exit 3 ("no inputs collected") is a clean scan — the adapter synthesizes an empty SARIF and exits 0. Any other non-zero exit, or invalid/runs-less SARIF, exits 2 (tool error). |

## Install paths

Zizmor has two install paths, both driven by the hash-pinned `tools/zizmor/requirements.txt` and kept fresh by Dependabot (pip ecosystem; see `.github/dependabot.yml`):

1. **CI / adopters** — the `tools/zizmor/Dockerfile` installs zizmor via `pip --require-hashes` into the tool image; `run.sh` runs that image (catalog `delivery: image`).
2. **Local test container** — `test/Dockerfile` installs zizmor the same way into a managed venv. `make zizmor` (and the default `./test.sh`) runs this copy against the wrangle repo so workflow security findings surface in the same `make test` loop as shellcheck and actionlint.

Pip refuses any artifact whose sha256 isn't in `requirements.txt`, so version and hashes always move together.

## Detection canary

`test.bats` runs the real binary against `fixtures/unpinned_uses.yml` — a deliberately tag-pinned action — and asserts the `unpinned-uses` audit still fires. The rest of the suite feeds synthetic SARIF, which proves the plumbing but never that zizmor still *detects* anything; the canary is the positive control that turns a false-negative regression (a zizmor version or config change that silently stops flagging a class) into a red test instead of a passing scan.
