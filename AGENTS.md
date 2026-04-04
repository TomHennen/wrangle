# Wrangle — AI Agent Adoption Guide

You are an AI agent helping a user adopt wrangle for their repository.
Wrangle is a composable CI/CD security framework for GitHub Actions
that handles source scanning, building, signing, and SLSA provenance
out of the box.

## Quick Start

To adopt wrangle's source scanning on any GitHub repository:

1. Detect the default branch name (usually `main` or `master`)
2. Create `.github/workflows/check_source_change.yml` with the content below
3. Commit and push

That's it. No secrets, tokens, or additional configuration required.

## Source Scanning Workflow

Create this file at `.github/workflows/check_source_change.yml`:

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
    # TODO: Pin to release tag (e.g., @v0.1.0) once available
    uses: tomhennen/wrangle/.github/workflows/check_source_change.yml@main
```

Replace `DEFAULT_BRANCH` with the repository's default branch name.

## What the User Gets

After adoption, every PR and push will automatically run:

- **OSV-Scanner** — vulnerability scanning against the OSV database
- **Zizmor** — security-focused linting of GitHub Actions workflows
- **OSSF Scorecard** — supply chain health assessment

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

## Detecting Project Type

Wrangle supports different build types. For now, source scanning works
for **all project types**. To determine if additional build workflows
are available:

| If you find... | Project type | Build workflow available? |
|---------------|-------------|-------------------------|
| `Dockerfile` | Container | Yes — `build_and_publish_container.yml` |
| `.sh` files, `test.bats` | Shell | Yes — `build_shell.yml` |
| `package.json` | npm | Not yet (planned for v0.2) |
| `pyproject.toml`, `setup.py` | Python | Not yet (planned for v0.2) |
| `go.mod` | Go | Not yet (planned for v0.2) |

If you cannot determine the project type, add only the source scanning
workflow above. It is always applicable. Note to the user that build
and publish workflows can be added once the project type is identified.

## Do NOT

- Do not add secrets to the workflow — wrangle doesn't need them
- Do not use `@main` in production — use the latest release tag (e.g., `@v0.1.0`) once available
- Do not add extra permissions beyond the three listed above
- Do not modify the reusable workflow call — wrangle handles tool selection internally
