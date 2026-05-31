# CLAUDE.md — Wrangle Development Guidelines

Wrangle is a composable CI/CD security framework for GitHub Actions. Because it is a **supply chain security tool**, its own code must be exemplary. A compromise of wrangle propagates to every adopter.

Read `docs/SPEC.md` before contributing. It is the source of truth for architecture and contracts; this file covers conventions and judgment calls that are not yet mechanically enforced.

## How to think about wrangle conventions

1. **Mechanical enforcement beats prose.** If a rule can be enforced by a lint, test, or CI check, do that — don't put it here. CLAUDE.md describes only what can't (yet) be mechanically caught.
2. **Prefer language parsers over grep for code analysis.** AST tools (ast-grep, shellcheck, mvdan/sh, semgrep) beat regex/awk for any code-rule enforcer.
3. **One sentence per rule.** Why → linked issue or commit message. What → here.
4. **Read upstream docs before integrating a tool.** Custom code (install.sh, CLI shims, verification logic) is the fallback path, not the default — you can't pick canonical package managers, attestation tiers, or built-in CLI options without looking. When adopting a new tool, the PR description must note what upstream install paths and verification mechanisms exist, and why the chosen one was picked.

## Code review checklist

Before approving any PR, ask:

- Does it adhere to `docs/SPEC.md` — both the explicit contracts and the design intent?
- Are the architectural choices consistent with the rest of the codebase, or do they invent new patterns without clear justification?
- Does it introduce needless complexity?
- Does it make adopters' lives easier, or harder?
- Is this code we'd be comfortable maintaining a year from now?
- Do CI checks pass?

Then check the diff against the conventions in the rest of this file.

**Re-verification by the original reviewer.** After review findings are addressed, the same reviewer verifies the fixes.

## Comments

Comments explain *why*, not *what*. Explain hidden constraints or non-obvious decisions; don't restate the code, narrate history, or reference PR numbers, review threads, comment URLs, or policy docs (CLAUDE.md, SPEC.md, DEP_MGMT.md) — the rule lives in the doc, the comment states the constraint. Delete obvious comments that just paraphrase the line below them. One line max unless a hidden constraint really requires more.

## Shell scripts

Every shell script MUST start with the exact preamble `set -euo pipefail` followed by `set -f` (disable globbing). Stricter supersets (`set -Eeuo pipefail`) and equivalent decompositions (`set -e -u -o pipefail`) are rejected — one canonical form. If you need ERR trap inheritance, add `set -E` on its own line after the preamble. Scripts that intentionally need globbing must wrap it in `set +f` / `set -f` with a comment, scoped as narrowly as possible. Sourced libs that toggle `set +f` MUST restore `set -f` before returning.

All variable expansions MUST be double-quoted. All scripts MUST pass `shellcheck` — no `# shellcheck disable` without a justifying comment. Use `$(command)` not backticks. Use `[[ ]]` not `[ ]` for conditionals. Use `printf` not `echo` for output that may contain user data.

Don't `curl | sh` — all binary downloads go through `lib/download_verify.sh`. These rules are mechanically enforced by `tools/wrangle-shell-lint/` (WSL001–005).

## GitHub Actions

- **Inline shell ≤ ~5 lines.** Longer or anything with logic → extract to a script.
- **No expression injection.** NEVER interpolate `${{ inputs.* }}`, `${{ github.event.* }}`, or any attacker-controllable expression directly in a `run:` block — always thread through `env:` first.
- **No copy-paste across workflows.** If the same `run:` block or step sequence appears in more than two workflow files, extract to a composite or shared script. Drift between copies is a class of bug, not a one-off.

## Action reference pinning

Required pin format per context (third-party actions, the SLSA-generator tag exception, self-references, examples), the `@main` prohibition, and how self-references are bumped: see [DEP_MGMT.md](DEP_MGMT.md).

## Installing and verifying tools

How to choose an install method and verification tier — the decision tree, the integrity-tier ladder, and the freshness-first rule — is in [DEP_MGMT.md](DEP_MGMT.md). Install-script mechanics (`lib/download_verify.sh`, `$WRANGLE_BIN_DIR`, idempotency, atomic `mv`) are the Install Script Interface contract in SPEC.md.

## Pins drift across files

Prevent the same pin literal drifting across files (single-source or a divergence-fail test): see [DEP_MGMT.md § Drift](DEP_MGMT.md#drift).

## Adapter contract (see SPEC.md §Adapter Script Interface for the full contract)

Adapters take `<src_dir>` (read-only) and `<output_dir>` (writable), write `output.sarif` (SARIF 2.1.0), exit 0 (no findings) / 1 (findings) / 2 (tool error). Do not write outside `output_dir`. Do not access secrets (env is stripped by the orchestrator). `jq` exit codes are checked — malformed SARIF MUST cause exit 2, not silent success.

## Per-tool directory layout

Tools live in `tools/<name>/`. Three patterns: **adapter** (`install.sh` + `adapter.sh` + `test.bats`, wired into `actions/scan/action.yml`) for scan tools; **action** (`action.yml` + `test.bats`) for tools with official GitHub Actions; **developer tooling** (whatever the tool needs + `test.bats`) for things used only during development, not by adopters (e.g., `bump_action_pins`, `wrangle-shell-lint`).

An action's own helper scripts live in its `actions/<name>/` directory alongside `action.yml`, **with their bats next to them** (`actions/<name>/*.bats`) so a test sits beside the thing it tests (e.g. `preflight_guard`, `verify`). `lib/` is only for helpers shared across multiple actions/tools (`env.sh`, `sanitize.sh`, `download_verify.sh`), and `test/` holds those shared-lib tests + cross-cutting ones.

## Path resolution

Scripts resolve paths relative to their own location via `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, never relative to `$PWD`. The scan action at `actions/scan/` must remain at that depth — moving it breaks all adopters.

## Testing

Always run `./test.sh` before pushing — CI runs the same checks. `./test.sh quick` skips zizmor for inner-loop iteration. Every adapter and install script gets a `test.bats`. The test-layer breakdown (local layers, the offline Docker unit suite, CI integration, e2e) is in SPEC.md §Testing Strategy. Beyond that:

- **Prefer real tools/binaries over shims/mocks.** Drive tests with the actual binary wherever practical; a shim is acceptable only with a one-line comment saying why a real tool can't be used (e.g., an adapter feeding deterministic fixture SARIF that no real scanner would emit on demand).
- **Unit vs. integration.** The Docker unit suite (`./test.sh`) is intentionally offline/hermetic for determinism — not because online checks belong only in CI. Integration tests need a real binary or network and have a dedicated CI job, but they also run locally whenever the prerequisites are present (`skip_or_fail` skips only when the binary or network is genuinely missing — running them locally catches problems early). A bats test lives next to the script it covers.
- **Tests must never skip in CI.** Skip paths exist as a safety net for sandboxed local dev (no network, no installed binary); in CI those preconditions are guaranteed, so a skip means coverage silently degraded. The test distinguishes CI from local and fails rather than skips (the shared `skip_or_fail` helper) — don't bolt a separate per-job CI step onto a test that skips.
- **A script may have a `main` that runs on execution.** Factoring logic into small, pure functions for unit tests is good, but don't over-rotate into "source the script then call a function" from callers — a script can expose testable helpers *and* a `main`/subcommand dispatcher guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]]`, so a caller just runs it.

## Supply chain discipline

- **No auto-merge of dependency updates.** New upstream tool versions are adopted after a delay (aim for 7 days) to let the community discover supply chain attacks before wrangle amplifies them.
- **No `curl | sh` anywhere.** All binary downloads go through `lib/download_verify.sh`.
- **No downloading checksums from the same source as binaries.** When checksums are used, they are hardcoded; version + checksum updates are always a single atomic commit.
- **Avoid linter / scanner suppressions; do it right.** If `shellcheck`, `actionlint`, `zizmor`, or a similar tool flags something, the default is to restructure the code so the finding goes away — not to add `# zizmor: ignore[...]` / `# shellcheck disable=...`. Suppressions are escape hatches for genuinely-false positives only, and carry a one-line justification.

## Dogfooding

Wrangle uses its own workflows. If a wrangle feature does not work on the wrangle repo itself, it is broken.

## Permissions

Workflows request minimum required permissions. Never blanket `permissions: write-all`. The standard set for source scanning is `actions: read`, `contents: read`, `security-events: write`. Add permissions only as needed, with a comment explaining why.

## Input validation

The orchestrator validates tool names against `^[a-z][a-z0-9_-]*$`. Any new input that flows into a shell command or file path MUST be validated against a strict allowlist or regex before use.

## Secrets

Adapters do NOT receive secrets (env stripped by the orchestrator). If a tool needs an authenticated API, use the `WRANGLE_EXTRA_` prefix mechanism (see SPEC.md). Never log secrets. `GITHUB_TOKEN` only where strictly necessary. The integration-test companion repo (see `test/integration/SPEC.md`) MUST NOT hold release signing keys, Cosign credentials, cross-repo tokens, GitHub App credentials, or SSH keys.

## Contributing process

- Branch from `main`, descriptive branch names.
- All PRs must pass CI (`make test` via GitHub Actions); shellcheck cleanly; actionlint cleanly.
- Spec changes (`docs/SPEC.md`) require discussion — open an issue first.
- Update `AGENTS.md` if the adoption interface changes.
- For personal-environment preferences that shouldn't be checked in (your local test command, your shell, your editor's quirks), use `CLAUDE.local.md` — it's git-ignored.

## Open work and future ideas

Open conventions still missing mechanical enforcement, scoped feature work, and design ideas live as GitHub issues. Search there before filing a new issue or scoping a new PR — the work you want to do may already be tracked.
