# CLAUDE.md — Wrangle Development Guidelines

Wrangle is a composable CI/CD security framework for GitHub Actions. Because it is a **supply chain security tool**, its own code must be exemplary. A compromise of wrangle propagates to every adopter.

Read `docs/SPEC.md` before contributing. It is the source of truth for architecture and contracts.

## Shell Script Safety

Every shell script MUST start with `set -euo pipefail`. Scripts that process arguments from external input MUST also `set -f` (disable globbing) before processing those arguments.

All variable expansions MUST be double-quoted: `"$var"`, `"${var}"`, `"$@"`. The only exception is intentional word-splitting with a documented comment explaining why it is safe (e.g., `$WRANGLE_TOOLS` in the composite action, which is validated by the orchestrator's regex).

All scripts MUST pass `shellcheck`. No `# shellcheck disable` without a comment justifying the exception.

Use `$(command)` not backticks. Use `[[ ]]` not `[ ]` for conditionals. Use `printf` not `echo` for output that may contain user data.

## Inline Shell in GitHub Actions

Prefer standalone scripts (in `lib/` or `tools/<name>/`) over inline `run:` shell blocks in action YAML files. Inline shell is harder to test, harder to lint, and harder to review. If a `run:` block exceeds ~5 lines or contains logic (conditionals, loops), extract it to a script and call that script from the `run:` block instead.

## GitHub Actions Expression Injection

NEVER interpolate `${{ inputs.* }}`, `${{ github.event.* }}`, or any attacker-controllable expression directly in a `run:` block. Always pass these through `env:` first:

```yaml
# CORRECT
env:
  VALUE: ${{ inputs.tools }}
run: echo "$VALUE"

# WRONG — enables injection
run: echo "${{ inputs.tools }}"
```

This applies to all workflow files, composite actions, and example workflows in `gh_workflow_examples/`.

## Action Reference Pinning

| Context | Required format |
|---------|----------------|
| Third-party actions in wrangle workflows | Full commit SHA with version comment: `uses: actions/checkout@<sha> # v4.2.2` |
| Wrangle's own actions in examples | Release tag: `@v0.1.0` |
| Wrangle internal cross-references (in reusable workflows) | Full SHA: `TomHennen/wrangle/actions/scan@<sha>` (temporary — see #136) |
| Wrangle internal cross-references (elsewhere) | Relative path: `./actions/scan` |

**Temporary: hardcoded self-references in reusable workflows.** GitHub resolves `uses: ./` relative to the caller's workspace, not the reusable workflow's repo. This means `uses: ./actions/scan` breaks for any external caller. Until GitHub ships the `$/` syntax (#136), reusable workflows use fully-qualified SHA-pinned refs (`TomHennen/wrangle/actions/scan@<sha>`). When composite actions change, update the SHA in the reusable workflow in the same commit. Non-reusable-workflow contexts (composite actions referencing other local actions) can still use `./` paths.

The `@main` ref MUST NOT appear in any `uses:` line in the repo, including examples and docs.

Dependabot manages GitHub Actions dependency updates. Tool binary versions are managed separately via `make update-tool` because Dependabot cannot update hardcoded checksums.

## Per-Tool Directory Structure

Every tool lives in `tools/<name>/`. There are two patterns:

**Adapter pattern** (standalone binaries, e.g., OSV-Scanner):
```
tools/<name>/
├── install.sh    # Downloads + verifies the tool binary
├── adapter.sh    # Runs the tool, produces SARIF
└── test.bats     # Tests for both scripts
```

**Action pattern** (tools with official GitHub Actions, e.g., Zizmor, Scorecard):
```
tools/<name>/
├── action.yml    # Composite action wrapping upstream action
└── test.bats     # Structural tests
```

Everything for one tool lives in one directory. To add a new tool, copy an existing `tools/<name>/` directory matching the appropriate pattern and adapt it. Then wire it into `actions/scan/action.yml`.

## Adapter Contract

Adapters take exactly two positional arguments: `<src_dir>` (read-only) and `<output_dir>` (writable). They MUST:
- Write `output.sarif` (SARIF 2.1.0) to `output_dir`
- Exit 0 (no findings), 1 (findings found), or 2 (tool error)
- NOT write files outside `output_dir`
- NOT access secrets (environment is stripped by the orchestrator)
- Check `jq` exit codes — malformed SARIF must cause exit 2, not silent success

## Install Script Contract

Install scripts MUST:
- Use `lib/download_verify.sh` for all downloads (never raw `curl | sh`)
- Verify integrity using the strongest method the upstream tool supports: SLSA provenance > Sigstore signature > hardcoded SHA-256 checksum. Provenance or signature verification is sufficient on its own — tools with SLSA/Sigstore do not need additional checksums.
- **NEVER fall back to a weaker verification method if a stronger one fails.** If a tool is configured for SLSA provenance verification and it fails, the install MUST abort. A verification failure may be a supply chain attack.
- Install to `$WRANGLE_BIN_DIR` (default: `$RUNNER_TEMP/.wrangle/bin`), never `/usr/local/bin`
- Be idempotent (skip if correct version already installed)
- Use atomic `mv` (not `cp`) to prevent TOCTOU races

For tools without SLSA provenance or Sigstore signatures, checksums are hardcoded in the install script (not downloaded alongside the binary). A version bump and its checksum update MUST be in the same commit.

## Path Resolution

The composite action at `actions/scan/action.yml` resolves the orchestrator via `${{ github.action_path }}/../../run.sh`. This means:
- The scan action MUST remain at depth `actions/scan/` (two directories below root)
- Moving it to a different depth breaks all adopters
- If the layout changes, update paths in the same commit

All shell scripts resolve paths relative to their own location using `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, never relative to `$PWD`.

## Testing

### Running tests

```bash
./test.sh          # Run all tests in Docker (preferred — no local deps needed)
make test          # Run locally if you have actionlint, shellcheck, bats installed
```

Always run `./test.sh` before pushing. CI runs the same checks.

### Test expectations

Every adapter and install script gets a `test.bats`. Write tests before or alongside the implementation. See `docs/SPEC.md` §Testing for the full test layer breakdown (actionlint, shellcheck, bats, SARIF validation) and fixture requirements.

### CI testing workflow

PR CI runs four checks: unit tests (`test.yml`), source scanning (`check_source_change.yml`), integration tests (`integration-test.yml`, which exercises reusable workflows cross-repo via the companion repo), and the Kusari Inspector.

**Before requesting review:**
- Confirm CI passes on the PR — check the Actions tab, not just local tests
- For tool changes: inspect the step summary (markdown table) and the `wrangle-scan-results` artifact in the CI logs to verify correct SARIF output and metadata
- If CI fails on something local tests don't catch, investigate — it may reveal a real environment difference

## Supply Chain Discipline

- **No auto-merge of dependency updates.** New upstream tool versions are adopted after a delay (aim for 7 days) to let the community discover supply chain attacks before wrangle amplifies them.
- **No `curl | sh` anywhere.** All binary downloads go through `lib/download_verify.sh`.
- **No downloading checksums from the same source as binaries.** When checksums are used (tools without provenance/signatures), they are hardcoded. Tool version + checksum updates are always a single atomic commit.

## Dogfooding

Wrangle uses its own workflows. If a wrangle feature does not work on the wrangle repo itself, it is broken. See `docs/SPEC.md` §Dogfooding for the full list of requirements.

## Permissions

Workflows request minimum required permissions. Never use blanket `permissions: write-all`. The standard set for source scanning is:

```yaml
permissions:
  actions: read
  contents: read
  security-events: write
```

Add permissions only as needed, with a comment explaining why.

## Input Validation

The orchestrator validates tool names against `^[a-z][a-z0-9_-]*$`. This prevents path traversal, shell injection, and glob expansion. Any new input that flows into a shell command or file path MUST be validated against a strict allowlist or regex before use.

## Secrets

- Adapters do NOT receive secrets. The orchestrator strips sensitive environment variables.
- If a tool needs an authenticated API, use the `WRANGLE_EXTRA_` prefix mechanism (see SPEC.md adapter environment section).
- Never log secrets. Never write secrets to SARIF, step summaries, or artifacts.
- `GITHUB_TOKEN` is only used where strictly necessary (e.g., Scorecard, container registry login) and is never passed to adapter scripts.
- The integration-test companion repo (see `test/integration/SPEC.md`) MUST NOT hold release signing keys, Cosign credentials, cross-repo tokens, GitHub App credentials, or SSH keys. Its only permitted secrets are `GITHUB_TOKEN` (scoped to the companion repo) and whatever each wrangle reusable workflow requires at dispatch time.

## Contributing Process

- Branch from `main`, use descriptive branch names
- All PRs must pass CI (`make test` via GitHub Actions)
- All shell scripts must pass shellcheck with zero warnings
- All action YAML must pass actionlint
- Spec changes (`docs/SPEC.md`) require discussion — open an issue first
- Update `AGENTS.md` if the adoption interface changes
