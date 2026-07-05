# wrangle-lint — Tool Specification

Audits an adopter repo's **configuration** for footguns that silently defeat
dependency hygiene — distinct from the security scanners (osv/zizmor/scorecard
check the adopter's code and workflows; this checks whether the surrounding
config is wired up). The checks are universal Dependabot best practices, not
wrangle-specific policy (see [Scope](#scope)).

| Property | Value |
|----------|-------|
| Pattern | Adapter (`tools/wrangle-lint/adapter.sh` + the first-party `wrangle-lint` Go binary) |
| Integrity verification | First-party Go (`tool` directive in `tools/go.mod`), built into the tool's image at image-build time; dependency integrity via go.sum / sum.golang.org (DEP_MGMT branch 1) |
| SARIF output | `$WRANGLE_METADATA_DIR/wrangle-lint/output.sarif` (written by the binary) |
| SARIF upload | Wrangle uploads with category `wrangle/wrangle-lint` |
| Default policy | `:fail` — config footguns block the check |
| Suppression | inline `# wrangle-lint: ignore WL00X -- justification` on the flagged line or the comment block directly above it (justification required) |

## Rules

| Rule | Level | What it flags |
|------|-------|---------------|
| WL001 | error | No effective Dependabot config — `.github/dependabot.yml` is missing, or present with no `updates` entries, so no update PRs run |
| WL002 | error | Config at `.github/dependabot.yaml` — Dependabot reads only `.yml`, so it is silently ignored |
| WL003 | error | A `github-actions` entry globs `directory`/`directories` with `**` — it does not recurse into nested `action.yml` (and `/**` provokes duplicate PRs) |
| WL004 | error | A composite `action.yml` directory in the repo is absent from the `github-actions` `directories` — its pins drift from the workflow copies |
| WL005 | warning | An updates entry has no `cooldown.default-days >= 7` — bumps land before the community can surface a supply-chain attack (7 days is a recommended baseline) |
| WL006 | error | Workflows under `.github/workflows` pin actions with `uses:`, but no `github-actions` ecosystem is configured — those action pins never get update PRs |

## Scope

Every rule is a **universal** Dependabot configuration best practice — none is
wrangle-specific. The only wrangle-specific choice is the **posture**: the tool
runs at `:fail` by default, so a footgun blocks the check. Adopters soften that
two ways:

- set `wrangle-lint:info` in the scan `tools` list to make all findings
  advisory, or
- suppress an individual finding inline (e.g. keep a shorter WL005 cooldown, or
  an intentional `/**` glob) with a justified `# wrangle-lint: ignore WL00X`.

## Testing

Rule-logic coverage (every rule, suppression, alias/multi-doc edge cases,
malformed-fails-closed, dogfood) and `run()` end-to-end are in the Go tests
(`main_test.go`, run by `make gotest`). The bats suite drives `adapter.sh`
against a PATH shim to pin the wrapper contract (exit-code mapping, SARIF
validity, argument handling) — the shim can emit the invalid-SARIF and
tool-error cases a real scanner never produces on demand.

## Known limitations

- WL006 flags a missing `github-actions` ecosystem when workflows pin actions;
  inferring *other* missing ecosystems from build workflows or manifests (e.g.
  `build_and_publish_npm` but no `npm` entry) is still tracked in #409.
- A *missing* `.github/dependabot.yml` has no line to anchor a comment to and is
  not inline-suppressible; the present-but-no-`updates` variant is (it's a real
  file), as is every other finding.
