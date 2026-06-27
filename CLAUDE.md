# CLAUDE.md — Wrangle Development Guidelines

Wrangle is a composable CI/CD security framework for GitHub Actions. Because it is a **supply chain security tool**, its own code must be exemplary — a compromise of wrangle propagates to every adopter.

Read `docs/SPEC.md` before contributing. It is the source of truth for architecture and contracts; this file covers conventions and judgment calls that are not yet mechanically enforced.

## How to think about wrangle conventions

1. **Mechanical enforcement beats prose.** If a rule can be enforced by a lint, test, or CI check, add it there and link that check — don't restate it here. CLAUDE.md describes only what can't (yet) be mechanically caught.
2. **Prefer language parsers over grep for code analysis.** AST tools (ast-grep, shellcheck, mvdan/sh, semgrep) beat regex/awk for any code-rule enforcer.
3. **One sentence per rule.** What → here; why → linked issue or commit message.
4. **Read upstream docs before integrating a tool.** Custom code (install.sh, CLI shims, verification logic) is the fallback, not the default. The adopting PR's description must note what upstream install paths and verification mechanisms exist, and why the chosen one was picked.

## Code review checklist

Before approving any PR, ask:

- Does it adhere to `docs/SPEC.md` — both the explicit contracts and the design intent?
- Are the architectural choices consistent with the rest of the codebase, or do they invent new patterns without clear justification?
- Does it introduce needless complexity?
- Does it make adopters' lives easier, or harder?
- Is this code we'd be comfortable maintaining a year from now?
- Do CI checks pass?

Then check the diff against the conventions below. After findings are addressed, the **same reviewer** verifies the fixes.

## Comments

- **Default to no comment.** Add one only for a genuinely non-obvious constraint, kept to one short line. Never restate what the code does, narrate rationale or history, or reference PR numbers, review threads, or policy docs — the rule lives in the doc, the comment states the constraint.
- **Describe current behavior, not history.** A reader who never saw the prior version is the audience — never "replaces the old X", "previously…", or "now does Y instead of Z". Migration rationale belongs in the PR, not the committed code.

## Adopter-facing docs

The per-build-type READMEs, `docs/verifying_artifacts.md`, the top-level `README.md`, and the workflow examples are **quick-start docs, not specifications.** Keep them at the altitude of *what the adopter does*, in the `README.md`'s benefit-first, second-person voice. Mechanism, rationale, and exhaustive rules live in `SPEC.md` (or the relevant upstream spec) and get a *link*.

- **State the fact, link the spec — don't reproduce it** ("the name is PEP 503-normalized (link)", not the algorithm).
- **Don't enumerate what a source of truth already lists** (workflow inputs/outputs live in the workflow file — point to it; copies drift).
- **Cut anything the adopter doesn't act on** — internal job mechanics, threat-model derivations, "under the hood" asides.
- **Unshipped work lives in issues, not docs.**

## Shell scripts

All shell conventions — preamble form, quoting, `printf` over `echo`, `[[ ]]` over `[ ]`, `curl | sh`, globbing / `set +f`, justified suppressions — are enforced by `tools/wrangle-shell-lint/` (WSL001–007) and `shellcheck`; the rule list lives there. Add new mechanical shell rules to the linter, not here.

## GitHub Actions

- **No copy-paste across workflows.** A `run:` block or step sequence appearing in more than two workflow files → extract to a composite or shared script. (The one rule here not yet mechanically caught.)
- Inline-shell length and expression injection (`${{ inputs.* }}` / `${{ github.event.* }}` or other attacker-controllable expressions in a `run:` body) are caught by `tools/wrangle-workflow-lint/` (WWL001–002) and zizmor; thread such expressions through `env:` first.

## Dependencies & pinning

- **Action reference pinning** — required pin format per context, the `@main` prohibition, and self-reference bumping: [DEP_MGMT.md](DEP_MGMT.md).
- **Installing and verifying tools** — install-method decision tree, integrity-tier ladder, and freshness-first rule: [DEP_MGMT.md](DEP_MGMT.md). Install-script mechanics (`lib/download_verify.sh`, `$WRANGLE_BIN_DIR`, idempotency, atomic `mv`) are the Install Script Interface contract in SPEC.md.
- **Pin drift across files** — single-source or a divergence-fail test: [DEP_MGMT.md § Drift](DEP_MGMT.md#drift).
- **Curated tool-image digests** (`tools/catalog.json`) — digest-pinned on the wrangle namespace, enforced by `tools/check_catalog.sh`; adoption-lag against `:latest` checked at release by `tools/check_catalog_freshness.sh` (fix with `tools/bump_catalog_digest.sh`).

## Adapter contract (full: SPEC.md §Adapter Script Interface)

- Take `<src_dir>` (read-only) and `<output_dir>` (writable); write `output.sarif` (SARIF 2.1.0).
- Exit 0 (no findings) / 1 (findings) / 2 (tool error) — malformed SARIF MUST exit 2 (checked via `jq` exit codes), not silent success.
- Do not write outside `output_dir` or access secrets.

## Layout & path resolution

Tools live in `tools/<name>/`, in one of three patterns:

- **adapter** — `adapter.sh` + `test.bats`; binary from a tools/go.mod `tool` directive or a bespoke `install.sh` for tools no package manager ships; wired into `actions/scan/action.yml`.
- **action** — `action.yml` + `test.bats`, for tools with official GitHub Actions.
- **developer tooling** — whatever it needs + `test.bats`, for things used only during development, not by adopters (e.g. `bump_action_pins`, `wrangle-shell-lint`).

Beyond the per-tool directory:

- An action's own helper scripts live beside its `action.yml` in `actions/<name>/`, with their bats next to them (`actions/<name>/*.bats`). `lib/` is only for helpers shared across actions/tools (`env.sh`, `sanitize.sh`, `download_verify.sh`); `test/` holds shared-lib and cross-cutting tests.
- Scripts resolve paths via `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, never `$PWD`. The scan action at `actions/scan/` must stay at that depth — moving it breaks all adopters.

## Testing

Run `make test` before pushing — it's the exact suite CI runs. With the host toolchain installed (the pinned set in `test/Dockerfile`), run it directly, or a single layer (`make bats`, `make shellcheck`). Otherwise use `./test.sh`, which runs the same suite in the pinned container; `./test.sh quick` skips zizmor for inner-loop iteration. The test-layer breakdown is in SPEC.md §Testing Strategy. Beyond that:

- **Prefer real tools/binaries over shims/mocks.** A shim is acceptable only with a one-line comment saying why a real tool can't be used.
- **Unit vs. integration is decided by the *dependency*, not the container.** A test needing a real binary or network is an integration test (dedicated CI job, also runs locally when prereqs are present), kept out of the unit suite so that suite stays deterministic. A bats test lives next to the script it covers.
- **Tests must never skip in CI.** Skip paths are a safety net for sandboxed local dev; in CI the preconditions are guaranteed, so a skip means coverage silently degraded. Use the shared `skip_or_fail` helper to fail rather than skip.
- **A script may have a `main` that runs on execution.** Expose testable helpers *and* a `main`/dispatcher guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]]` — don't force callers to source-and-call.

## Supply chain discipline

- **No `curl | sh` anywhere.** All binary downloads go through `lib/download_verify.sh`.
- **No auto-merge of dependency updates.** Adopt new upstream versions after a delay (7-day cooldown, enforced by `wrangle-lint` WL005) to let the community discover supply chain attacks first.
- **No downloading checksums from the same source as binaries.** Checksums are hardcoded; version + checksum updates are always a single atomic commit.
- **Avoid linter/scanner suppressions; do it right.** Restructure the code so the finding goes away rather than adding `# zizmor: ignore[...]` / `# shellcheck disable=...`. Suppressions are for genuine false positives only, with a one-line justification.

## Dogfooding

Wrangle uses its own workflows. If a wrangle feature does not work on the wrangle repo itself, it is broken.

A PR that changes a composite action (or a file it reads, like a `policies/*.hjson` PolicySet) and wires it into a reusable workflow needs a **bootstrap pin**: the nested `uses: TomHennen/wrangle/actions/<name>@<sha>` self-reference is fetched from its pinned (main) SHA, not the PR head, so the integration test otherwise runs the old action. The pin → merge → bump lifecycle and the `check_pin_ancestry` control are in [docs/e2e_testing.md](docs/e2e_testing.md).

For throwaway end-to-end experiments before promoting to the integration companion or `wrangle-test`, use the scratch repos [`TomHennen/wrangle-agent-playground`](https://github.com/TomHennen/wrangle-agent-playground) (public) and [`TomHennen/wrangle-agent-playground-private`](https://github.com/TomHennen/wrangle-agent-playground-private) (private — for private-repo-specific behavior like Advanced-Security SARIF upload or attestation) — commit/push/PR there freely; nothing in them is permanent.

## Security

- **Least privilege.** Workflows request minimum permissions — never blanket `permissions: write-all`; the standard set for source scanning is `actions: read`, `contents: read`, `security-events: write`. Add more only as needed, with a comment explaining why.
- **Validate every new input.** The orchestrator checks tool names against `^[a-z][a-z0-9_-]*$`; any new input flowing into a shell command or file path MUST be checked against a strict allowlist or regex before use.
- **Secrets.** Adapters do NOT receive secrets (env stripped by the orchestrator); a tool needing an authenticated API uses the `WRANGLE_EXTRA_` prefix (see SPEC.md). Never log secrets; use `GITHUB_TOKEN` only where strictly necessary. The integration-test companion repo (`test/integration/SPEC.md`) MUST NOT hold release signing keys, Cosign credentials, cross-repo tokens, GitHub App credentials, or SSH keys.

## Contributing process

- Branch from `main` with descriptive names; PRs must pass CI (`make test`), shellcheck, and actionlint cleanly.
- **Don't delete a branch that's the base of an open stacked PR** — GitHub auto-closes the dependent; rebase dependents onto `main` first (and `--delete-branch` fails from inside a worktree, where `main` is checked out elsewhere).
- **No merge without an `LGTM` from the repository owner** — green CI alone is never authorization to merge.
- If a PR fully fixes a tracked issue, close it from the description with a closing keyword (`Fixes #NNN`); if unsure it fully resolves the issue, ask the owner.
- Update the README and `gh_workflow_examples/` if the adoption interface changes.
- For personal-environment preferences that shouldn't be checked in, use `CLAUDE.local.md` (git-ignored).

## Open work and future ideas

Open conventions still missing mechanical enforcement, scoped feature work, and design ideas live as GitHub issues. Search there before filing a new issue or scoping a new PR.
