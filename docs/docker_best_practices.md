## Ecosystem Best Practices Research: Docker / Container

Research into best practices for the Docker/container ecosystem — wrangle's first build-type target.

### Docker Ecosystem: Tool Decisions

**Dockerfile linting: Hadolint** (must have, v0.1 — 1 new binary)
- Undisputed standard. AST-based Dockerfile linter (~10k stars).
- Embeds ShellCheck to lint bash inside `RUN` instructions.
- Single static binary (Haskell, compiled). SARIF output.
- Rules cover Docker's own best practices: pin versions, COPY over ADD, non-root USER, minimize layers.
- Configurable via `.hadolint.yaml` (ignore rules, trusted registries, severity overrides).
- **Belongs in source scan stage** (every PR), not build stage. A Dockerfile is source code.
- All alternatives rejected: `dockerfile-lint` (abandoned), `dockerfilelint` (too few rules, no ShellCheck), Docker Engine `--check` (syntax only, not best practices).

**SBOM generation: BuildKit-native** (must have, v0.1 — no new binary)
- `docker buildx build --sbom=true` runs Syft during the build, produces SPDX, attaches as in-toto attestation to image manifest.
- **Build-time SBOMs are strictly better than post-hoc scanning:** BuildKit sees the filesystem at each build stage, including intermediates discarded in multi-stage builds. Post-hoc scanners only see the final layer.
- No Syft binary needed — it's embedded in BuildKit.
- No Trivy needed — see vulnerability scanning below.
- SPDX format by default (ecosystem-native choice). OSV-Scanner consumes it.

**Vulnerability scanning: OSV-Scanner on the build-time SBOM** (must have, v0.1 — no new binary)
- Extract SBOM from built image → feed to OSV-Scanner → SARIF.
- **One vulnerability scanner across both source and build stages.** No Trivy, no Grype, no second scanner with conflicting results.
- Trivy was initially considered but rejected: build-time SBOMs make post-hoc image scanning redundant, and two scanners create the "disagreeing results" problem.
- **Severity gating (decision needed):** Block on CRITICAL, warn on HIGH, allow override. Is this the right default?

**Provenance: Dual-attestation model** (must have, v0.1)

This is the key architectural decision. Wrangle produces **two layers of provenance:**

**Layer 1 — BuildKit-native (ecosystem-native):**
- `docker buildx build --provenance=mode=max` generates SLSA-formatted provenance attached to the image manifest.
- Rich metadata: full Dockerfile, build args, base image digests, VCS info.
- Inspectable via `docker buildx imagetools inspect`.
- **Critical caveat:** BuildKit attestations are **not cryptographically signed** — they're just OCI image layers. Anyone with registry push access can tamper with them.

**Layer 2 — Canonical SLSA L3 via `slsa-github-generator`:**
- `slsa-github-generator`'s container generator produces signed, isolated provenance.
- **Cryptographically signed** (Sigstore, non-forgeable).
- **Builder isolation** (reusable workflow the caller can't control = SLSA L3).
- **Cross-ecosystem verifiable** (`slsa-verifier`, Ampel).
- **Advances SLSA adoption** — adopters get canonical SLSA provenance as a side effect.

Both attestations attach to the same image (different predicateTypes, no conflict). Docker consumers read the BuildKit provenance. SLSA policy engines read the slsa-github-generator provenance.

**Why both:** Many ecosystem-native provenance solutions use old SLSA versions, lack signing, or use proprietary formats. The BuildKit provenance gives immediate ecosystem value. The SLSA provenance prepares adopters for policy enforcement and advances the spec. Wrangle bridges the gap.

**Image signing: Cosign** (must have, v0.1 — already in wrangle)
- Keyless signing via Sigstore OIDC.
- Also used for verification and for non-Docker ecosystems.

**Image testing: container-structure-test** (should have, v0.1 — 1 optional binary)
- Google's tool for validating built images via YAML-defined tests (file existence, command output, metadata).
- Tar driver works without Docker daemon. Standalone Go binary.
- **Opt-in:** runs only if `container-structure-test.yaml` exists. No test file = skip with advisory note.
- **Decision needed:** include in v0.1 or defer to v0.2?

### What wrangle adds to a container project (zero config)

**Source stage (every PR/push):**
1. Hadolint — Dockerfile best practices + bash bugs in RUN
2. OSV-Scanner — source dependency vulnerabilities
3. Zizmor — GitHub Actions workflow security
4. OSSF Scorecard — supply chain health

**Build stage (on main/release):**
5. docker buildx — BuildKit build with caching + multi-platform
6. BuildKit SBOM — build-time SPDX via embedded Syft
7. BuildKit provenance — ecosystem-native (`mode=max`)
8. OSV-Scanner — scans build-time SBOM (blocks on CRITICAL)
9. container-structure-test — image validation (if tests exist)

**Publish + Verify stage:**
10. Image pushed to ghcr.io with SBOM + BuildKit provenance attached
11. slsa-github-generator — canonical SLSA L3 provenance (signed, isolated)
12. Cosign — image signature

### Applying to future build types

| Build type | Native SBOM | Native provenance | SLSA provenance (always) |
|-----------|-------------|-------------------|--------------------------|
| **Container** | BuildKit `--sbom=true` | BuildKit `--provenance=mode=max` | slsa-github-generator/container |
| **npm** | `npm sbom` | `npm publish --provenance` | slsa-github-generator/generic |
| **Python** | `cyclonedx-py` from lockfile | PyPI Trusted Publishers | slsa-github-generator/generic |
| **Go** | `cyclonedx-gomod` from go.sum | None (SLSA only) | slsa-github-generator/go |
| **Generic** | Syft (post-hoc fallback) | None (SLSA only) | slsa-github-generator/generic |

### Net new binaries for v0.1

| Binary | Ecosystem | Required? |
|--------|-----------|-----------|
| Hadolint | Docker | Yes (1 binary) |
| container-structure-test | Docker | Optional (1 binary) |

Everything else is either on the runner already (docker/buildx, Cosign) or already in wrangle (OSV-Scanner, Zizmor, Scorecard). slsa-github-generator is a reusable workflow, not a binary.

---

Full reports with detailed analysis of all considered alternatives, rejected options, and open questions are available as artifacts in the conversation that produced this research.