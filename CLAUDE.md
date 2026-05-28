# CLAUDE.md — Wrangle Development Guidelines

Wrangle is a composable CI/CD security framework for GitHub Actions. Because it is a **supply chain security tool**, its own code must be exemplary. A compromise of wrangle propagates to every adopter.

Read `docs/SPEC.md` before contributing. It is the source of truth for architecture and contracts; this file covers conventions and judgment calls that are not yet mechanically enforced.

## How to think about wrangle conventions

1. **Mechanical enforcement beats prose.** If a rule can be enforced by a lint, test, or CI check, do that — don't put it here. CLAUDE.md describes only what can't (yet) be mechanically caught.
2. **Prefer language parsers over grep for code analysis.** AST tools (ast-grep, shellcheck, mvdan/sh, semgrep) beat regex/awk for any code-rule enforcer.
3. **One sentence per rule.** Why → linked issue or commit message. What → here.
4. **Read upstream docs before integrating a tool.** Custom code (install.sh, CLI shims, verification logic) is the fallback path, not the default — you can't pick canonical package managers, attestation tiers, or built-in CLI options without looking.

## Code review checklist

Before approving any PR, ask:

**Big picture:**
- Does it adhere to `docs/SPEC.md` — both the explicit contracts and the design intent?
- Are the architectural choices consistent with the rest of the codebase, or do they invent new patterns without clear justification?
- Overall code quality: is this code we'd be comfortable maintaining a year from now?

**Specific failure modes we've hit:**
- Does this fail closed on tool error?
- Is every new invariant pinned by a regression test?
- Does it prefer mechanical enforcement over prose CLAUDE.md additions?
- Does it use canonical package managers / strongest available verification, not a "this is awkward" deflection?
- Are comments load-bearing (`# Why:`) rather than narrating history or restating the diff?

## Comments

Explain *why* something non-obvious is done, not *what* the code does. Don't narrate history ("previous implementation used X"), don't restate the diff, don't reference PR numbers in code. One line max unless a hidden constraint really requires more.

## Shell scripts

Every shell script MUST start with `set -euo pipefail` and `set -f` (disable globbing). Scripts that intentionally need globbing must wrap it in `set +f` / `set -f` with a comment, scoped as narrowly as possible. Sourced libs that toggle `set +f` MUST restore `set -f` before returning.

All variable expansions MUST be double-quoted. All scripts MUST pass `shellcheck` — no `# shellcheck disable` without a justifying comment. Use `$(command)` not backticks. Use `[[ ]]` not `[ ]` for conditionals. Use `printf` not `echo` for output that may contain user data.

These rules are mechanically enforced by `tools/wrangle-shell-lint/` (WSL001–005). A `curl | sh` ban (WSL006) is a planned follow-up.

## GitHub Actions

- **Inline shell ≤ ~5 lines.** Longer or anything with logic → extract to a script. Mechanical enforcement is a planned follow-up.
- **No expression injection.** NEVER interpolate `${{ inputs.* }}`, `${{ github.event.* }}`, or any attacker-controllable expression directly in a `run:` block — always thread through `env:` first. Mechanical enforcement is a planned follow-up.

## Action reference pinning

| Context | Required format |
|---|---|
| Third-party actions | Full commit SHA with version comment: `uses: actions/checkout@<sha> # v4.2.2` |
| SLSA generator (exception) | Release tag only: `@v2.1.0` ([slsa-verifier#12](https://github.com/slsa-framework/slsa-verifier/issues/12)) |
| Wrangle's own actions in examples | Release tag: `@v0.1.0` |
| Wrangle internal cross-references in reusable workflows | Full SHA (temporary — see #136) |
| Wrangle internal cross-references elsewhere | Relative path: `./actions/scan` |

`@main` MUST NOT appear in any `uses:` line, including examples and docs. Dependabot manages third-party action updates; tool binary versions are manual. When composite actions change, update the SHA in any reusable-workflow self-references in the same commit.

## Install method and verification (see SPEC.md §Install Script Interface for the full contract)

**Integrity verification hierarchy:** SLSA provenance > Sigstore signature > GitHub release attestation > hardcoded SHA-256 checksum. NEVER fall back to a weaker method if a stronger one fails.

**Install method hierarchy:** canonical package manager (with adequate verification) > GitHub release binary + attestation > GitHub release binary + sha256. When upstream offers multiple package managers, prefer in order: (1) the one upstream's install docs recommend first, (2) the one with attestation support, (3) the one that doesn't add transitive runtime deps to the test image. If upstream is on pipx/cargo/npm/go-install and the test image already has that runtime, use it. Don't write a custom `install.sh` if upstream supports a canonical package manager with adequate verification — that's the fallback, not the default.

**Convenience is not a fallback justification.** "We'd have to install one more tool in the image" or "the attestation flow is awkward at build time" are NOT reasons to drop to a weaker tier. The fallback rule is "stronger verification is genuinely unavailable upstream" — document *why* the stronger tier doesn't exist, not why it'd be inconvenient.

**Drift between two pins.** If a version, checksum, or SHA lives in two files (e.g., a tool pinned in both `test/Dockerfile` and `tools/<name>/action.yml`), either consolidate to a single source or add a regression test that diffs the two locations and fails on divergence.

All downloads go through `lib/download_verify.sh`. Install to `$WRANGLE_BIN_DIR`, never `/usr/local/bin`. Be idempotent. Use atomic `mv` (not `cp`).

## Adapter contract (see SPEC.md §Adapter Script Interface for the full contract)

Adapters take `<src_dir>` (read-only) and `<output_dir>` (writable), write `output.sarif` (SARIF 2.1.0), exit 0 (no findings) / 1 (findings) / 2 (tool error). Do not write outside `output_dir`. Do not access secrets (env is stripped by the orchestrator). `jq` exit codes are checked — malformed SARIF MUST cause exit 2, not silent success.

## Per-tool directory layout

Tools live in `tools/<name>/`. Three patterns: **adapter** (`install.sh` + `adapter.sh` + `test.bats`, wired into `actions/scan/action.yml`) for scan tools; **action** (`action.yml` + `test.bats`) for tools with official GitHub Actions; **developer tooling** (whatever the tool needs + `test.bats`) for things used only during development, not by adopters (e.g., `bump_action_pins`, `wrangle-shell-lint`).

## Path resolution

Scripts resolve paths relative to their own location via `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, never relative to `$PWD`. The scan action at `actions/scan/` must remain at that depth — moving it breaks all adopters.

## Testing

Always run `./test.sh` before pushing — CI runs the same checks. `./test.sh quick` skips zizmor for inner-loop iteration. Every adapter and install script gets a `test.bats`. See SPEC.md §Testing Strategy for the test-layer breakdown.

## Supply chain discipline

- **No auto-merge of dependency updates.** New upstream tool versions are adopted after a delay (aim for 7 days) to let the community discover supply chain attacks before wrangle amplifies them.
- **No `curl | sh` anywhere.** All binary downloads go through `lib/download_verify.sh`.
- **No downloading checksums from the same source as binaries.** When checksums are used, they are hardcoded; version + checksum updates are always a single atomic commit.

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
