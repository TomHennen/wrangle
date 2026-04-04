## Ecosystem Best Practices Research: Shell

Research into best practices for the shell ecosystem — wrangle's own native language and one of the two v0.1 target ecosystems.

### Cross-Cutting Principles

Three principles should guide all ecosystem best practices decisions:

1. **Build-time SBOMs are always preferable.** SBOMs generated during the build — by the build tool itself — are more accurate and trustworthy than post-hoc scanning.
2. **Use ecosystem-native tooling where available.** Prefer the ecosystem's own tools over generic bolt-on solutions.
3. **Always produce canonical SLSA provenance in addition to ecosystem-native attestations.** Many native provenance solutions use old SLSA versions or proprietary formats. Generate both: ecosystem-native (for ecosystem consumers) + canonical SLSA L3 via `slsa-github-generator` (for cross-ecosystem policy engines and to advance SLSA adoption).

### Shell Ecosystem: Tool Decisions

**Linting: ShellCheck** (must have, v0.1)
- Undisputed standard. 36k+ GitHub stars, 10+ years mature.
- Detects quoting errors, injection risks, deprecated syntax, uninitialized variables.
- Standalone binary. Native SARIF-compatible output.
- Hadolint (Docker linter) embeds ShellCheck for `RUN` instructions — that's how standard it is.
- No other shell linter is worth considering.

**Formatting: shfmt** (must have, v0.1)
- De facto standard. Single Go binary.
- AST-based parsing (not regex). Supports bash/POSIX/mksh/bats.
- Supports Google Shell Style Guide out of the box (`shfmt -i 2 -ci`).
- Diff mode (`shfmt -d`) for CI — exit non-zero on formatting differences.
- **Decision needed:** Default to Google style (`-i 2 -ci`). Allow override via `.editorconfig`.
- **Decision needed:** Should formatting check be blocking or advisory? Recommendation: blocking by default.

**Testing: bats-core** (must have, v0.1)
- Most widely used shell testing framework (~5k stars).
- TAP-compliant output (standard test protocol, CI-friendly).
- Supports setup/teardown, parallel execution, plugin ecosystem (bats-assert, bats-mock, bats-file).
- Bash-only, but wrangle mandates bash so this isn't a limitation.
- Wrangle already uses bats-core internally — dogfooding.

**Rejected alternatives:**
- *shunit2* — POSIX shell support is nice but no test isolation (tests leak state), no built-in mocking. Dated.
- *ShellSpec* — most feature-rich (BDD, built-in mocking, coverage), but custom DSL has learning curve. Less community adoption. Could revisit for v0.2 if demand exists.
- *Super Linter / MegaLinter* — bundles ShellCheck + shfmt + 40 other linters in a ~2GB Docker image. Architecturally opposed to wrangle's binary-download approach. Only covers linting (no vuln scanning, SBOMs, provenance). Not suitable.

**Security scanning:** ShellCheck covers shell security (injection, quoting, eval dangers). No additional security-specific tool needed.

**Vulnerability scanning:** Shell scripts don't have package managers. OSV-Scanner (already in wrangle) handles any lockfiles in the repo. No shell-specific vuln scanning needed.

### What wrangle adds to a shell project (zero config)

| Tool | What it does |
|------|-------------|
| ShellCheck | Lint all `.sh` files for bugs, security issues, deprecated syntax |
| shfmt | Enforce consistent formatting (Google style default) |
| bats-core | Run existing `.bats` tests |
| OSV-Scanner | Scan for vulnerable dependencies (if lockfiles exist) |
| Zizmor | Lint GitHub Actions workflows |
| OSSF Scorecard | Supply chain health assessment |