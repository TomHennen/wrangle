# PROTOTYPE — Install Script Interface as invariants + enforcement pointers

> Not for merge as-is. This converts `docs/SPEC.md` §"Install Script Interface"
> (current lines 389–516, ~127 lines of prose) into the proposed format so the
> two can be compared side by side. See the note at the bottom for what changed
> and why.

---

## Install Script Interface

Each tool that downloads a standalone binary ships a `tools/<name>/install.sh`,
invoked by the orchestrator (`run.sh`), never by users directly.

### Contract (adopter- and maintainer-facing; stable)

| | |
|---|---|
| **Location** | `tools/<name>/install.sh` |
| **Usage** | `install.sh [version]` — `version` optional, defaults to a pinned known-good value in the script |
| **Stdout** | the installed version |
| **Exit 0** | installed, or correct version already present |
| **Exit 1** | any failure (download, verification, placement) |

### Invariants

Each invariant is followed by the check that enforces it, or `⚠ prose
load-bearing` where nothing mechanical does yet (these are the backlog of checks
worth writing).

- **Idempotent** — re-running with the pinned version already installed is a
  no-op. → `tools/osv/test.bats` "skips if correct version already installed";
  `tools/syft/test.bats` same.
- **Confined install dir** — binaries land in `$WRANGLE_BIN_DIR` (default
  `$RUNNER_TEMP/.wrangle/bin`), never a system dir such as `/usr/local/bin`.
  → `tools/syft/test.bats` "uses WRANGLE_BIN_DIR" and "no curl | sh, no
  /usr/local/bin".
- **No `curl | sh`** — every download routes through `lib/download_verify.sh`.
  → shell-lint **WSL006** (`tools/wrangle-shell-lint`); `tools/syft/test.bats`
  "no curl | sh".
- **Atomic placement** — the verified binary is moved into place with `mv` from
  a temp file, never `cp`, to close the version-check→placement TOCTOU window.
  → `test/lib/test_download_verify.bats` "uses atomic mv to place binary".
- **Fail-closed download** — a failed download exits non-zero and deletes the
  temp file. → `test/lib/test_download_verify.bats` "cleans up temp file on
  checksum failure" / "fails after max retries exhausted"; `tools/osv/test.bats`
  "fails if binary download fails".
- **One method, no fallback** — each tool uses exactly one verification method,
  fixed at development time; if it fails the install aborts and never retries a
  weaker method. This is the load-bearing security invariant.
  → `tools/osv/test.bats` "fails if provenance verification fails";
  `tools/syft/test.bats` "aborts when cosign verification fails" / "aborts when
  binary not listed in checksums".
- **Hardcoded checksums** — when a tool uses SHA-256, the digest is hardcoded in
  the script, never fetched alongside the binary; a version bump updates it in
  the same commit. → ⚠ prose load-bearing — no lint asserts this, and no
  download-pattern tool currently uses bare SHA-256 (see tier table), so there
  is no live example to test against.

### Verification tiers

One method per tool, chosen at development time by what upstream publishes. No
runtime fallback between tiers — a failure in the chosen tier is the end of the
install.

| Tier | Choose when upstream… | Tools today | Enforced by |
|---|---|---|---|
| 1. SLSA provenance | publishes SLSA attestations | osv-scanner | `tools/osv/test.bats` (provenance download + verify-fail) |
| 2. Sigstore signature | cosign-signs releases, no full SLSA | syft | `tools/syft/test.bats` (cosign identity pin + verify-fail) |
| 3. Hardcoded SHA-256 | offers neither | *(none today)* | ⚠ no live example |
| 4. `go install` / sum.golang.org | has no binary release at all | govulncheck (inside `build/actions/go`) | ⚠ lives outside `tools/`; covered by `build/actions/go/test.bats`, not an `install.sh` |

Tier 4 is a narrow exception for Go-module tools with no published binary; its
gating conditions (pinned semver, `GOSUMDB`/`GOPROXY` not disabled) live in
CLAUDE.md §"Supply Chain Discipline". sum.golang.org gives transparency-log
immutability, **not** publisher authentication — a compromised maintainer's
release still installs; detection is after-the-fact.

### Rationale (why no-fallback, why sum.golang.org isn't authentication, the
`GOPROXY=...,direct` nuance) → moved to `docs/decisions/` ADR, not inlined here.

---

## What changed and why

**~127 prose lines → ~55, and it now self-reports its own staleness.**

1. **Two live drift bugs surfaced just by writing it this way.**
   - The current spec (line 461) says *"Tools with checksum only: Zizmor."*
     Zizmor is an **action-pattern** tool — `tools/zizmor/action.yml` + pip
     `requirements.txt`, **no `install.sh`** — so it uses none of this contract.
     Stale line.
   - *"Tools with Sigstore signatures: (to be determined per tool)"* (line 460)
     is now concretely **syft**.
   These were invisible in 127 lines of prose; the tier table forces a current
   answer per tool.

2. **Every invariant now points at its test/lint.** A reader (human or agent)
   can confirm the rule is real and live, and the `⚠` markers become a precise
   backlog: "hardcoded-checksum has no enforcement and no example" is now a
   visible gap, not buried in a paragraph.

3. **Duplicated-from-code removed.** The numbered `BEHAVIOR` / `download/verify
   flow` lists restated what `install.sh` and `lib/download_verify.sh` already
   do; they're gone in favor of the invariants that aren't obvious from reading
   one script.

4. **Rationale relocated, not deleted.** The no-fallback justification and the
   `GOPROXY=...,direct` essay are real design reasoning but don't belong in the
   always-loaded contract — they move to an ADR and are referenced by one line.

5. **What was kept verbatim in spirit:** the no-fallback rule and the
   sum.golang.org "immutability ≠ authentication" caveat. These are security
   invariants that are only *partly* mechanically enforced, so the prose is
   still load-bearing and stays.
