# wrangle-lint — Tool Specification

Audits an adopter repo's wrangle-relevant **configuration** for footguns that
silently defeat wrangle's protections — distinct from the security scanners
(osv/zizmor/scorecard check the adopter's code and workflows; this checks
whether the surrounding config is wired up to deliver what wrangle promises).

| Property | Value |
|----------|-------|
| Pattern | Adapter (`tools/wrangle-lint/adapter.sh` + `check.py`) |
| Integrity verification | PyYAML hash-pinned in `tools/wrangle-lint/requirements.txt`, installed `--require-hashes` into an isolated venv (DEP_MGMT branch 3; Dependabot bumps version + hashes atomically) |
| SARIF output | `$WRANGLE_METADATA_DIR/wrangle-lint/output.sarif` (written by adapter) |
| SARIF upload | Wrangle uploads with category `wrangle/wrangle-lint` |
| Default policy | `:fail` — config footguns block the check |
| Suppression | inline `# wrangle-lint: ignore WL00X -- justification` on the flagged line or the comment block directly above it (justification required) |

## Rules

| Rule | Level | What it flags |
|------|-------|---------------|
| WL001 | warning | No `.github/dependabot.yml` — update PRs never run |
| WL002 | error | Config at `.github/dependabot.yaml` — Dependabot reads only `.yml`, so it is silently ignored |
| WL003 | error | A `github-actions` entry globs `directory`/`directories` with `**` — it does not recurse into nested `action.yml` (and `/**` provokes duplicate PRs) |
| WL004 | error | A composite `action.yml` directory in the repo is absent from the `github-actions` `directories` — its pins drift from the workflow copies |
| WL005 | warning | An updates entry has no `cooldown.default-days >= 7` — bumps land before the community can surface a supply-chain attack |

## Known limitations

- Ecosystem-coverage inference (a `go.mod`/`package.json` present but its
  ecosystem missing from `updates`) is tracked separately — it relies on
  manifest detection and belongs at `:info` until proven, so it is not yet a
  rule here.
- WL001 (missing file) has no line to anchor a suppression comment to, so it
  is not suppressible inline.
