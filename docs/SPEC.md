# Wrangle v0.1 Specification

## Vision

Project maintainers should ship features securely without tracking security tooling details. Security engineers should update tools and best practices without bothering maintainers.

Wrangle is a composable CI/CD security framework for GitHub Actions that provides:

1. **One-shot adoption** — a single workflow file gives you vulnerability scanning, workflow security linting, supply chain scoring, SBOM generation, and provenance
2. **Pluggable tools** — new security tools are added via adapters without changing adopting repos
3. **Automatic updates** — adopters reference wrangle's reusable workflow; updates flow to everyone
4. **AI-agent friendly** — designed so "Claude, adopt wrangle for this repo" just works

## Architecture

### Layers

```
┌──────────────────────────────────────────────────┐
│  Adopting Repo                                   │
│  .github/workflows/check_source_change.yml       │
│  (calls wrangle's reusable workflow)             │
└──────────────────┬───────────────────────────────┘
                   │ uses:
┌──────────────────▼───────────────────────────────┐
│  Wrangle Reusable Workflow                       │
│  .github/workflows/check_source_change.yml       │
│  (orchestrates composite actions)                │
└──────────────────┬───────────────────────────────┘
                   │ uses:
┌──────────────────▼───────────────────────────────┐
│  Wrangle Composite Action                        │
│  source/actions/scan/action.yml                  │
│  (installs tools, runs adapters, uploads results)│
└──────────────────┬───────────────────────────────┘
                   │ calls
┌──────────────────▼───────────────────────────────┐
│  Orchestrator + Adapters                         │
│  source/run.sh → source/install/*.sh             │
│                → source/adapters/*.sh            │
│  (download binaries, run tools, normalize output)│
└──────────────────────────────────────────────────┘
```

### Directory Layout

```
wrangle/
├── source/
│   ├── adapters/           # Tool adapter scripts (one per tool)
│   │   ├── osv.sh
│   │   └── zizmor.sh
│   ├── install/            # Tool installation scripts (one per tool)
│   │   ├── osv.sh
│   │   └── zizmor.sh
│   ├── run.sh              # Orchestrator
│   └── actions/
│       ├── scan/
│       │   └── action.yml  # Composite action entry point
│       └── scorecard/
│           └── action.yml  # OSSF Scorecard wrapper
├── build/
│   └── actions/
│       └── container/
│           └── action.yml  # Container build/publish action
├── tools/
│   └── format_sarif_summary.sh  # SARIF → markdown summary
├── gh_workflow_examples/   # Copy-paste templates for adopters
├── test/                   # Tests (bats, fixtures, schemas)
├── docs/
│   └── SPEC.md             # This document
└── CLAUDE.md               # AI agent adoption instructions
```

---

## Tool Adapter API

### Adapter Script Interface

Each adapter in `source/adapters/` wraps a security tool with a standard interface.

**Contract:**

```
USAGE:  adapter.sh <src_dir> <output_dir>

ARGUMENTS:
  src_dir     Path to the source code to scan (read-only)
  output_dir  Path to write results (writable, already exists)

OUTPUT FILES (written to output_dir):
  output.sarif   REQUIRED  SARIF 2.1.0 JSON
  output.md      OPTIONAL  Human-readable markdown summary
  output.txt     OPTIONAL  Human-readable plain text (fallback if no .md)

EXIT CODES:
  0  Scan completed, no findings
  1  Scan completed, findings detected
  2  Scan failed (tool error)

PRECONDITIONS:
  Tool binary is on $PATH (handled by install script)
  jq is available
```

### Install Script Interface

Each script in `source/install/` downloads and caches a tool binary.

**Contract:**

```
USAGE:  install.sh [version]

ARGUMENTS:
  version  Optional. Pinned version to install. Defaults to a known-good version
           hardcoded in the script.

BEHAVIOR:
  1. Check if correct version is already installed; exit 0 if so
  2. Detect OS (linux/darwin) and arch (amd64/arm64)
  3. Download binary from tool's official release page
  4. Place on $PATH
  5. Print installed version to stdout

EXIT CODES:
  0  Installed successfully (or already present)
  1  Installation failed
```

### Orchestrator Interface

`source/run.sh` installs and runs multiple adapters.

**Contract:**

```
USAGE:  run.sh [-s <src_dir>] [-o <output_dir>] <tool1> [tool2] ...

OPTIONS:
  -s src_dir     Source directory to scan (default: .)
  -o output_dir  Output directory for results (default: ./metadata)

ARGUMENTS:
  tool1, tool2   Adapter names to run (e.g., osv, zizmor)

BEHAVIOR:
  For each tool:
    1. Run source/install/<tool>.sh
    2. Create <output_dir>/<tool>/
    3. Run source/adapters/<tool>.sh <src_dir> <output_dir>/<tool>/
    4. Record pass/fail status

  After all tools:
    5. Print summary table to stdout

EXIT CODES:
  0  All tools passed with no findings
  1  At least one tool found issues
  2  At least one tool failed to run

NOTES:
  The orchestrator resolves adapter and install script paths relative to its
  own location (using $0 / BASH_SOURCE), not the caller's working directory.
  This is critical for portability when called via github.action_path.
```

---

## Composite Action Interface

The scan action (`source/actions/scan/action.yml`) is the primary entry point for GitHub Actions users.

```yaml
name: Wrangle Source Scan
description: Scan source code with wrangle security tools

inputs:
  tools:
    description: "Space-separated list of tools to run (default: all)"
    required: false
    default: "osv zizmor"

# No secrets required — tools are downloaded as public binaries
```

**Behavior:**
1. Checks out the calling repo
2. Runs the orchestrator with specified tools
3. Runs OSSF Scorecard
4. Generates a markdown summary in the GitHub Actions step summary
5. Uploads SARIF to GitHub Code Scanning
6. Uploads all results as an artifact

**Portability:** All internal paths use `${{ github.action_path }}` so the action works when called from any repo.

---

## Reusable Workflow Interface

The reusable workflow (`.github/workflows/check_source_change.yml`) wraps the composite action for `workflow_call` consumers.

```yaml
on:
  workflow_call:
    inputs:
      tools:
        description: "Space-separated list of tools to run"
        required: false
        type: string
        default: "osv zizmor"
# No secrets required
```

**Adopter workflow (what goes in the adopting repo):**

```yaml
name: Check Source Change
on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["**"]

jobs:
  check-change:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@v0.1.0
```

This is the entire file an adopter needs. No secrets, no configuration, no dependencies to manage.

---

## Supported Tools (v0.1)

| Tool | Type | What it does |
|------|------|-------------|
| [OSV-Scanner](https://github.com/google/osv-scanner) | Vulnerability scanner | Scans dependencies against the OSV database |
| [Zizmor](https://github.com/woodruffw/zizmor) | Workflow linter | Security-focused linting of GitHub Actions workflows |
| [OSSF Scorecard](https://scorecard.dev/) | Supply chain scoring | Assesses repo security health across 18+ categories |

### Adding a New Tool

To add a tool named `foo`:

1. Create `source/install/foo.sh` following the install script contract
2. Create `source/adapters/foo.sh` following the adapter script contract
3. Add `foo` to the default tool list in `source/actions/scan/action.yml`
4. Add bats tests in `test/adapters/test_foo.bats`

No Docker images, no registry management, no workflow changes for adopters.

---

## Design Decisions

### Binary downloads over Docker images

**Previous approach:** Tools were wrapped in Docker images, pushed to ghcr.io, and run via `docker run` with volume mounts.

**New approach:** Tools are downloaded as standalone binaries and run directly.

**Rationale:**
- **Speed:** No image pull latency (cached binary downloads are near-instant)
- **Simplicity:** No container registry to manage, no image build pipeline
- **Portability:** Works on any runner (macOS, self-hosted, ARM — not just Linux with Docker)
- **Testability:** No Docker-in-Docker complexity; scripts testable with bats-core locally
- **Adoption friction:** No authentication needed to pull tool images

The container *build/publish* workflow (for building adopters' Docker images) remains unchanged.

### Reusable workflow + composite action (two layers)

The reusable workflow exists so adopters get a clean `uses:` interface with `workflow_call`. The composite action exists so the implementation can use `${{ github.action_path }}` for path resolution. GitHub requires this split because reusable workflows cannot use `github.action_path`.

### SARIF as the universal output format

All tools produce SARIF 2.1.0. This enables:
- Upload to GitHub Code Scanning (appears in Security tab)
- Consistent programmatic processing across tools
- A single summary formatter for all tools

Human-readable output (markdown/text) is optional and used only for step summaries.

---

## Testing Strategy

### Local (fast, TDD-friendly)

```bash
make test    # Runs all local checks
```

Layers:
1. **actionlint** — validates all workflow and action YAML files
2. **shellcheck** — lints all shell scripts
3. **bats-core** — unit tests for adapters, install scripts, orchestrator, and formatter
4. **SARIF schema validation** — validates fixture/output SARIF against the 2.1.0 JSON schema

### CI (integration)

`.github/workflows/test.yml` runs `make test` plus integration tests that exercise the composite action via `uses: ./source/actions/scan`.

### End-to-end (cross-repo)

[TomHennen/Concordance](https://github.com/TomHennen/Concordance) serves as the external test repo. A successful run there proves the full adoption path works.

---

## Adoption Path

### For humans

1. Copy the workflow from `gh_workflow_examples/check_source_change.yml` into your repo at `.github/workflows/check_source_change.yml`
2. Adjust the branch name if your default branch isn't `main`
3. Push. Done.

### For AI agents

See `CLAUDE.md` in the repo root. The instructions enable any AI coding agent to adopt wrangle with a single command like "adopt wrangle for this repo."

### Long-term: OpenSSF contribution

The adapter pattern, tool composition logic, and profile system are candidates for contribution to OpenSSF (e.g., as part of Minder or a new working group). The spec and implementation will be designed with this handoff in mind.

---

## Roadmap

### v0.1.0 (this spec)
- [ ] Adapter API implemented (OSV, Zizmor)
- [ ] Binary download installation (no Docker)
- [ ] Portable composite action (`github.action_path`)
- [ ] SARIF upload enabled
- [ ] Testing infrastructure (actionlint + shellcheck + bats)
- [ ] Tested on Concordance
- [ ] CLAUDE.md for AI agent adoption

### v0.2.0 (future)
- [ ] Profile system (`wrangle.yml` with `profile: container` / `profile: library`)
- [ ] `wrangle init` CLI or GitHub Action for bootstrapping
- [ ] Additional tools (e.g., Semgrep, Trivy)
- [ ] Build workflow portability fixes

### v1.0.0 (future)
- [ ] OpenSSF contribution proposal
- [ ] Stable adapter API with versioning guarantees
- [ ] Multi-CI support (GitLab, etc.)
