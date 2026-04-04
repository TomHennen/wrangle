# Wrangle Adoption Guide for AI Agents

You are an AI agent helping a user adopt wrangle for their repository.
Wrangle is a composable CI/CD security framework for GitHub Actions
that handles source scanning, building, signing, and SLSA provenance
out of the box.

## Quick Start

To adopt wrangle on any GitHub repository:

1. Detect the default branch name (usually `main` or `master`)
2. Detect the project type (see below)
3. Create the appropriate workflow files
4. Commit and push

No secrets, tokens, or additional configuration required.

---

## Step 1: Source Scanning (always add this)

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

This gives the user:
- **OSV-Scanner** — vulnerability scanning against the OSV database
- **Zizmor** — security-focused linting of GitHub Actions workflows
- **OSSF Scorecard** — supply chain health assessment

Results appear in the GitHub Actions step summary, the Security tab
(if Code Scanning is enabled), and as downloadable artifacts.

---

## Step 2: Detect Project Type and Add Build Workflow

Check the repository for these indicators:

| If you find... | Project type | Action |
|---------------|-------------|--------|
| `Dockerfile` | Container | Add the container build workflow (below) |
| `.sh` files, `test.bats` | Shell | Add the shell build workflow (below) |
| `package.json` | npm | Not yet supported (planned for v0.2) |
| `pyproject.toml`, `setup.py` | Python | Not yet supported (planned for v0.2) |
| `go.mod` | Go | Not yet supported (planned for v0.2) |
| None of the above | Unknown | Add only source scanning (Step 1) |

If you cannot determine the project type, add only the source scanning
workflow. Note to the user that build/publish workflows can be added
once the project type is identified.

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

### Shell Build Workflow

For shell projects (`.sh` files, `test.bats`), create `.github/workflows/build_shell.yml`:

```yaml
name: Shell Build
on:
  push:
    branches: ["DEFAULT_BRANCH"]
  pull_request:
    branches: ["**"]
  workflow_dispatch:

jobs:
  shell-build:
    permissions:
      contents: read
    # TODO: Pin to release tag (e.g., @v0.1.0) once available
    uses: tomhennen/wrangle/.github/workflows/build_shell.yml@main
```

Replace `DEFAULT_BRANCH`. This runs shellcheck on all `.sh` files and
bats tests if present.

---

## Permissions Explained

### Source scanning
| Permission | Why |
|-----------|-----|
| `actions: read` | Required by Scorecard to assess workflow security |
| `contents: read` | Required to check out and scan the source code |
| `security-events: write` | Required to upload SARIF results to the Security tab |

### Container build (additional)
| Permission | Why |
|-----------|-----|
| `id-token: write` | Required for Sigstore OIDC signing |
| `packages: write` | Required to push images to ghcr.io |

### Shell build
| Permission | Why |
|-----------|-----|
| `contents: read` | Required to check out and lint the source code |

---

## Do NOT

- Do not add secrets to the source scanning workflow — it doesn't need them
- Do not use `@main` in production — use the latest release tag once available
- Do not add extra permissions beyond what's listed above
- Do not modify the reusable workflow calls — wrangle handles tool selection internally
