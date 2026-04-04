# Wrangle Adoption Guide for AI Agents

You are an AI agent helping a user adopt wrangle for their repository.
Wrangle is a composable CI/CD security framework for GitHub Actions
that handles source scanning, testing, building, signing, and SLSA
provenance out of the box.

## Quick Start

To adopt wrangle on any GitHub repository:

1. Detect the default branch name (usually `main` or `master`)
2. Create the source checking workflow (always)
3. If the project builds artifacts, create the appropriate build workflow
4. Commit and push

No secrets, tokens, or additional configuration required for source checking.

---

## Step 1: Source Checking (always add this)

Create `.github/workflows/check_source_change.yml`:

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

This single workflow gives the user **both security scanning and project testing**:

**Security scanning** (all projects):
- **OSV-Scanner** — vulnerability scanning against the OSV database
- **Zizmor** — security-focused linting of GitHub Actions workflows
- **OSSF Scorecard** — supply chain health assessment

**Testing and linting** (auto-detected by project type):
- **Shell projects** — shellcheck on all `.sh`/`.bats` files, runs bats tests
- Additional project types planned for v0.2

Results appear in the GitHub Actions step summary, the Security tab
(if Code Scanning is enabled), and as downloadable artifacts.

---

## Step 2: Add Build Workflow (if applicable)

Build workflows are only needed for projects that produce publishable
artifacts. If the project is a library, script, or doesn't build
anything, Step 1 is sufficient.

| If you find... | Project type | Action |
|---------------|-------------|--------|
| `Dockerfile` | Container | Add the container build workflow (below) |
| `package.json` | npm | Not yet supported (planned for v0.2) |
| `pyproject.toml`, `setup.py` | Python | Not yet supported (planned for v0.2) |
| `go.mod` | Go | Not yet supported (planned for v0.2) |
| None of the above | No build needed | Step 1 is sufficient |

### Container Build Workflow

For projects with a `Dockerfile`, create `.github/workflows/build_and_publish_container.yml`:

```yaml
name: Build and Publish Container
on:
  push:
    branches: ["DEFAULT_BRANCH"]
    tags: ["v*"]
  pull_request:
    branches: ["**"]
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

jobs:
  build-and-publish:
    permissions:
      contents: read
      actions: read
      id-token: write
      packages: write
    # TODO: Pin to release tag (e.g., @v0.1.0) once available
    uses: tomhennen/wrangle/.github/workflows/build_and_publish_container.yml@main
    with:
      path: PATH_TO_DOCKERFILE_DIRECTORY
      imagename: ghcr.io/${{ github.repository }}/IMAGE_NAME
      registry: 'ghcr.io'
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
```

Replace `DEFAULT_BRANCH`, `PATH_TO_DOCKERFILE_DIRECTORY`, and `IMAGE_NAME`.

---

## Permissions Explained

### Source checking (Step 1)
| Permission | Why |
|-----------|-----|
| `actions: read` | Required by Scorecard to assess workflow security |
| `contents: read` | Required to check out and scan the source code |
| `security-events: write` | Required to upload SARIF results to the Security tab |

### Container build (Step 2, additional)
| Permission | Why |
|-----------|-----|
| `id-token: write` | Required for Sigstore OIDC signing |
| `packages: write` | Required to push images to ghcr.io |

---

## Do NOT

- Do not add secrets to the source checking workflow — it doesn't need them
- Do not use `@main` in production — use the latest release tag once available
- Do not add extra permissions beyond what's listed above
- Do not modify the reusable workflow calls — wrangle handles tool selection and test detection internally
