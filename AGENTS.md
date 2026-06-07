# Wrangle — AI Agent Adoption Guide

You are an AI agent helping a user adopt wrangle for their repository.
Wrangle is a composable CI/CD security framework for GitHub Actions
that handles source scanning, building, signing, and SLSA provenance
out of the box.

## Quick Start

Pick the path that matches the repository:

- **The repo builds an artifact** (container, Python, npm, Go, or shell) — adopt the matching `build_and_publish_*` / `build_shell.yml` workflow. It scans the source *and* builds, signs, and publishes in one run, so you do **not** also add `check_source_change.yml`. See [Build Workflows](#build-workflows).
- **The repo has no wrangle build type** — adopt source scanning only via `check_source_change.yml`. See [Source Scanning Workflow](#source-scanning-workflow).

Either way: detect the default branch name (usually `main` or `master`), create the workflow file, commit, and push. No secrets, tokens, or additional configuration required.

Also enable Dependabot from `gh_workflow_examples/dependabot.yml`, but do not configure auto-merge — wrangle's supply-chain discipline favors a ~7-day delay before adopting new versions. (Dependabot covers the user's own dependencies; wrangle's pinned internals are bumped by wrangle.)

## Source Scanning Workflow

Use this when the repo has no wrangle build type. Create this file at `.github/workflows/check_source_change.yml`:

```yaml
name: Check Source Change
on:
  push:
    branches: ["DEFAULT_BRANCH"]
  pull_request:
    branches: ["**"]
  workflow_dispatch:

jobs:
  check-change:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: tomhennen/wrangle/.github/workflows/check_source_change.yml@v0.1.0
```

Replace `DEFAULT_BRANCH` with the repository's default branch name.

## What the User Gets

After adoption, every PR and push will automatically run:

- **OSV-Scanner** — vulnerability scanning against the OSV database
- **Zizmor** — security-focused linting of GitHub Actions workflows
- **OSSF Scorecard** — supply chain health assessment
- **dependency-review** — flags vulnerable or disallowed dependency changes in a PR

Results appear in:
- The GitHub Actions step summary (markdown table)
- The GitHub Security tab (SARIF findings, if Code Scanning is enabled)
- Downloadable artifacts (full SARIF files)

## Permissions Explained

| Permission | Why |
|-----------|-----|
| `actions: read` | Required by Scorecard to assess workflow security |
| `contents: read` | Required to check out and scan the source code |
| `security-events: write` | Required to upload SARIF results to the Security tab |

No other permissions are needed. No secrets are required.

## Build Workflows

If the repo builds an artifact, prefer the matching build workflow — it
runs the source scan *and* builds/signs/publishes, so the standalone
`check_source_change.yml` is redundant:

| If you find... | Project type | Build workflow |
|---------------|-------------|----------------|
| `Dockerfile` | Container | `build_and_publish_container.yml` |
| `.sh` files, `test.bats` | Shell | `build_shell.yml` |
| `package.json` | npm | `build_and_publish_npm.yml` |
| `pyproject.toml`, `setup.py` | Python | `build_and_publish_python.yml` |
| `go.mod` | Go | `build_and_publish_go.yml` |

Copy-pasteable callers, required permissions, and how to verify the
output live in each [workflow example](gh_workflow_examples/README.md)
and `build/actions/<type>/README.md`.

Two notes for every build workflow:

- **`scan-tools` input** — space-separated source-scan tools, default
  `"osv zizmor scorecard:info dependency-review"`. Suffix a tool with
  `:info` to make it non-blocking; empty string disables scanning. A
  load-bearing (`:fail`) finding blocks publishing.
- **Caller permissions** — grant `security-events: write` so scan SARIF
  reaches the Security tab. Omitting it does not break the build or the
  gate (findings still appear in the step summary and the
  `wrangle-scan-results` artifact); only Security-tab upload is lost.

If you cannot determine the project type, add only the source scanning
workflow above. It is always applicable. Note to the user that a build
and publish workflow can be added once the project type is identified.

## Verifying Your Work (CI Testing)

PR CI tests the actual code in the PR branch, not `main`, because wrangle's own actions use `./` relative paths. This means your changes are exercised in CI before merge.

**After pushing a PR:**
1. Check the Actions tab — confirm CI passes (don't rely only on local tests)
2. For tool changes: inspect the step summary and the `wrangle-scan-results` artifact to verify SARIF output and metadata are correct
3. If CI fails, investigate before re-pushing — it may reveal a real environment difference

**What CI does not cover:**
- Cross-repo consumption (`uses: tomhennen/wrangle/...@v0.1.0`) is only testable after tagging a release. If your change affects the reusable workflow interface, note this in the PR description.

## Do NOT

- Do not add secrets to the workflow — wrangle doesn't need them
- Do not use `@main` in production — always use a release tag (e.g., `@v0.1.0`)
- Do not add extra permissions beyond those listed for the workflow you adopt
- Do not configure Dependabot auto-merge — adopt new versions only after a delay (see Quick Start)
