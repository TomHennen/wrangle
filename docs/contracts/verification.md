# Integrity Verification

The cross-cutting integrity contract for every binary wrangle downloads before
executing it. `docs/contracts/install_script.md` references this for its
per-tool verification tier; the helper functions live in
`lib/download_verify.sh`.

Transport is always HTTPS. On top of that, every tool is pinned to **exactly
one** content-verification tier, chosen at development time by what upstream
publishes. There is **no runtime fallback** between tiers: a failure in the
chosen tier aborts the install — it never retries a weaker one.

## Verification tiers

One method per tool. HTTPS is the always-required transport baseline beneath all
four.

| Tier | Choose when upstream… | Tools today | Enforced by |
|---|---|---|---|
| 1. SLSA provenance | publishes SLSA attestations | osv-scanner | `tools/osv/test.bats` "osv install: fails if provenance verification fails" |
| 2. Sigstore signature | cosign-signs releases (no full SLSA) | syft | `tools/syft/test.bats` "syft install: aborts when cosign verification fails" |
| 3. Hardcoded SHA-256 | offers neither | *(none today)* | ⚠ no live example |
| 4. `go install` / sum.golang.org | has no binary release at all | govulncheck (inside `build/actions/go`) | `build/actions/go/test.bats` "go.checks (L4): install_govulncheck pins GOPROXY and GOSUMDB on go install" |

**Tier 2 nuance (syft):** the cosign signature is over a `checksums.txt`, not
over the binary directly. The signature anchors `checksums.txt`; the binary is
then matched against an entry in it. So this tier *does* co-download a checksum
file (raw curl) — that is safe because cosign establishes its integrity before
it is trusted. The "hardcoded, never co-downloaded" rule below applies only to
tier 3.

**Tier 4 is a narrow exception** for Go-module tools with no published binary.
sum.golang.org gives transparency-log **immutability, not publisher
authentication** — a compromised maintainer's bad release would still install;
detection is after-the-fact. Its acceptance gate (pinned semver, trusted Go
toolchain, `GOPROXY`/`GOSUMDB` not disabled) lives in CLAUDE.md §"Supply Chain
Discipline". It lives outside `tools/` (no `install.sh`), so it is covered by
`build/actions/go/test.bats`, not by this directory's install-script contract.

## Invariants

Each invariant is followed by the test that enforces it, or `⚠ prose
load-bearing` where nothing mechanical does yet.

- **No runtime fallback between tiers** — if the chosen method fails, the install
  fails, even if a weaker method (e.g. a checksum) would have passed. A
  verification failure may signal a supply chain attack; silently downgrading
  would mask it. This is the load-bearing security invariant.
  → `tools/osv/test.bats` "osv install: fails if provenance verification fails";
  `tools/syft/test.bats` "syft install: aborts when cosign verification fails".
- **Verifier-absent is a failure, not a bypass** — `wrangle_verify_provenance`
  and `wrangle_verify_signature` return 1 when slsa-verifier / cosign is not on
  PATH; callers MUST NOT treat a missing verifier as a pass.
  → `test/lib/test_download_verify.bats` "verify_provenance: fails when
  slsa-verifier not on PATH" / "verify_signature: fails when cosign not
  available".
- **Tier-3 checksums are hardcoded, never co-downloaded** — when a tool uses bare
  SHA-256, the digest is pinned in its install script (not fetched alongside the
  binary, which would let an attacker who controls the binary also control its
  expected hash) and is updated in the same commit as the version bump.
  → ⚠ prose load-bearing — no lint asserts this, and no tool currently uses tier
  3, so there is no live example to test against.
- **Checksum mismatch aborts and cleans up** — `wrangle_download_verify` exits 1
  on a wrong SHA-256 and deletes the temp file, leaving nothing partial behind.
  → `test/lib/test_download_verify.bats` "download_verify: fails with wrong
  checksum" / "download_verify: cleans up temp file on checksum failure".
- **Bounded retries, then fail-closed** — transient download failures are retried
  up to 3 times with exponential backoff; exhausting them exits 1.
  → `test/lib/test_download_verify.bats` "download_verify: retries on download
  failure" / "download_verify: fails after max retries exhausted".
- **Atomic placement** — the verified binary is moved into place with `mv` from a
  temp file, never `cp`, closing the verify→placement TOCTOU window.
  → `test/lib/test_download_verify.bats` "download_verify: uses atomic mv to
  place binary".
- **Single shared library** — all install scripts route downloads through
  `lib/download_verify.sh` rather than rolling their own, so a security fix
  applies everywhere.
  → `tools/osv/test.bats` "osv install: sources download_verify library".

## Helper library

`lib/download_verify.sh` exposes `wrangle_download_verify` (download +
SHA-256), `wrangle_verify_provenance` (SLSA), and `wrangle_verify_signature`
(Sigstore). Their signatures and bodies live in that file; the invariants above
capture what callers may rely on.
