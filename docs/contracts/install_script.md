# Install Script Interface

Each tool that downloads a standalone binary ships a `tools/<name>/install.sh`,
invoked by the orchestrator (`run.sh`), never by users directly. It downloads,
verifies, and places one binary on `$PATH`.

## Contract

| | |
|---|---|
| **Location** | `tools/<name>/install.sh` |
| **Usage** | `install.sh [version]` — `version` optional, defaults to a pinned known-good value in the script |
| **Stdout** | the installed version |
| **Exit 0** | installed, or correct version already present |
| **Exit 1** | any failure (download, verification, placement) |

## Invariants

Each invariant is followed by the check that enforces it, or `⚠ prose
load-bearing` where nothing mechanical does yet — those `⚠` are the backlog of
checks worth writing.

- **Idempotent** — re-running with the pinned version already installed is a
  no-op. → `tools/osv/test.bats` "osv install: skips if correct version already
  installed"; `tools/syft/test.bats` "syft install: skips if correct version
  already installed".
- **Confined install dir** — binaries land in `$WRANGLE_BIN_DIR` (default
  `$RUNNER_TEMP/.wrangle/bin`), never a system dir such as `/usr/local/bin`. →
  `tools/syft/test.bats` "syft install: uses WRANGLE_BIN_DIR", "syft install: no
  curl | sh, no /usr/local/bin".
- **No `curl | sh`** — every download routes through `lib/download_verify.sh`. →
  shell-lint **WSL006** (`tools/wrangle-shell-lint`); `tools/syft/test.bats`
  "syft install: no curl | sh, no /usr/local/bin".
- **One method, no fallback** — each tool uses exactly one verification method,
  fixed at development time; a failure aborts the install rather than retrying a
  weaker method. This is the load-bearing security invariant — see
  [verification.md](verification.md) for the tier ladder and its enforcement.
- **Hardcoded checksums** — when a tool uses SHA-256, the digest is hardcoded in
  the script, never co-downloaded with the binary; a version bump updates it in
  the same commit. → ⚠ prose load-bearing — no lint asserts this, and no
  download-pattern tool currently uses bare SHA-256, so there is no live example.

The download → verify → atomic-placement flow and the four verification tiers
(SLSA provenance / Sigstore signature / hardcoded SHA-256 / `go install` via
sum.golang.org) are specified once in **[verification.md](verification.md)**,
which every install script depends on. Tools today: osv-scanner (provenance),
syft (Sigstore signature). See verification.md for the per-tier tool list and
the `⚠` gaps (tier 3 has no live tool).
