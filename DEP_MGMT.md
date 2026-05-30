# Dependency management

How wrangle pins, verifies, and upgrades every kind of dependency it consumes.
This is the canonical strategy; [`CLAUDE.md`](CLAUDE.md) holds the one-line rules
and points here for the rationale and per-category detail.

Wrangle's product runtime is shell — composite GitHub Actions, `lib/*.sh`, and
`run.sh`. There is no `go.mod`, `package.json`, `Cargo.toml`, or `pyproject.toml`
in the tree. (`tools/osv/testdata/vulnerable_go.mod` is a deliberately-vulnerable
scanner *test fixture*, not a project manifest — never onboard it to Dependabot.)
So wrangle's real dependency surface is **upstream tool references and binaries
pulled at install/build time**, each verified at an integrity tier defined in
[`CLAUDE.md` § Install method and verification](CLAUDE.md).

## Decision tree: how to install and verify a new dependency

Work top-down and stop at the first branch that matches. The governing rule is
CLAUDE.md's integrity-tier ladder: **use the strongest tier the publisher
actually supports, and never drop to a weaker one for convenience** — "we'd have
to install one more tool" is not a justification; "the stronger tier is genuinely
unavailable upstream" is (and must be documented in the PR).

```
What are you adding?
│
├─ A GitHub Action you `uses:` ?
│    ├─ a wrangle self-reference (TomHennen/wrangle/…)
│    │     → in a reusable workflow: pin  @<40-hex sha> # main YYYY-MM-DD ;
│    │       bump with `make bump-action-pins` (and BY HAND if it lives outside
│    │       .github/workflows/ — the bumper doesn't reach those yet; see Drift).
│    │       From one composite action to a sibling: use a relative path
│    │       `./actions/…` instead of a pin.
│    ├─ the SLSA generator reusable workflow
│    │     → tag-pin  @vX.Y.Z  + inline `# zizmor: ignore[unpinned-uses]`.
│    │       The ONLY sanctioned tag-only ref: its OIDC identity verification
│    │       keys off the tag, so a SHA pin is impossible (slsa-verifier#12).
│    └─ any other third-party action
│          → pin  @<40-hex sha> # vX ;  Dependabot (github-actions) bumps it;
│            zizmor (unpinned-uses / impostor-commit) enforces the SHA pin.
│
├─ A language/package dependency (belongs in a real manifest — go.mod,
│  package.json, requirements.txt) ?
│     → use the package manager + its lockfile/hashes; declare the ecosystem in
│       .github/dependabot.yml so the version AND hashes bump together.
│       (wrangle's product is shell; today this is only the pip *dev* tools.)
│
├─ A CLI tool / binary fetched at install or build time ?   ← the common case.
│  First — is there a canonical package-manager release (pip / cargo / npm /
│  go install / brew) whose verification is at least as strong as any binary
│  option? If so, USE THE PACKAGE MANAGER — it is the strong default. When
│  several exist, prefer (1) the one upstream's docs recommend, (2) the one with
│  attestation support, (3) the one adding the fewest transitive runtime deps to
│  the image. Binary + attestation and binary + sha256 below are FALLBACKS for
│  tools with no adequately-verified PM release — not free-choice alternatives.
│
│  Otherwise, walk the verification tiers; STOP at the first the publisher supports:
│
│     1. Ships SLSA provenance?  → curl binary + provenance, verify, STOP:
│          • attest-build-provenance sigstore bundle → `gh attestation verify`
│              (--signer-workflow pins the builder identity).
│              [introduced by the Ampel verify integration, #247]
│          • slsa-github-generator provenance        → `slsa-verifier verify-artifact`
│              (osv-scanner, via lib/download_verify.sh `wrangle_verify_provenance`)
│          • a bnd-style multi-line attestations.jsonl bundle → verify against
│              THAT format; confirm the release's shape before reusing another
│              tool's invocation — it is not the same as a single *.provenance.json.
│
│     2. Else ships a sigstore signature over a checksums file?
│          → `cosign verify-blob` the checksums against the publisher identity,
│            then sha256 the binary against the verified checksums.
│            (syft — Anchore publishes no provenance; `wrangle_verify_signature`)
│
│     3. Else a pure-Go tool that ships NO provenance/signature?
│          → `go install module@vX.Y.Z` (sum.golang.org) is acceptable AS ITS
│            NATIVE TIER; track it as a go.mod `tool` directive to gain Dependabot
│            coverage.  (govulncheck)
│            ✗ Do NOT use `go install` for a tool that DOES ship provenance or a
│              signature — sum.golang.org attests first-seen immutability, not
│              publisher authenticity, so it would DOWNGRADE the tier.
│
│     4. Else (nothing published)?
│          → hardcoded SHA-256 from a trusted out-of-band source, pinned in the
│            installer, with a comment explaining why nothing stronger exists.
│            Last resort.
│
│     Then, for every binary regardless of tier:
│       • the installer FAILS CLOSED and never falls back to a weaker tier at
│         runtime (a failed check may be an attack, not a glitch);
│       • single-source the version (the `VERSION="${1:-X}"` default in the one
│         install.sh; the actions invoke it with no version arg so the literal
│         isn't duplicated). If a version literal must repeat across files, add a
│         divergence-fail test;
│       • freshness is MANUAL today — Dependabot can't read install scripts, and
│         `go install` would downgrade the tier (#264 tracks automating this).
│
└─ An OS/apt package, or a container base image (test/build image only) ?
      → pin the apt package version (don't rely on the base image alone); pin the
        base image by @sha256: digest. Dev/CI-only; manual upgrade.
```

Whatever the branch: per CLAUDE.md, a PR adopting a new tool must state what
upstream install paths and verification mechanisms exist and why the chosen one
was picked. And keep the footprint minimal — use the smallest tool that does the
job (`unzip` over `python3`, `jq` over a Python script); don't add a language
runtime to the image for a one-liner.

Operational install-script mechanics (route downloads through
`lib/download_verify.sh`, install to `$WRANGLE_BIN_DIR`, be idempotent, atomic
`mv`) are the Install Script Interface contract — see `SPEC.md`.

## Dependency categories

| # | Category | Where | Pin format |
|---|---|---|---|
| 1 | Third-party GitHub Actions | `.github/workflows/`, `actions/`, `build/actions/`, `tools/*/action.yml` | `@<40-hex sha> # vX` |
| 2 | SLSA generator reusable workflows | `build_and_publish_{python,npm,go,container}.yml` | tag only `@vX.Y.Z` (sanctioned exception) |
| 3 | Wrangle self-refs in `.github/workflows/` | reusable workflows | `@<sha> # main YYYY-MM-DD` |
| 4 | Wrangle self-refs outside workflows | e.g. `actions/scan/action.yml` | `@<sha> # main YYYY-MM-DD` |
| 5 | Upstream `main`-tracking workflow | `compute_slsa_source.yml` | `@<sha> # main` |
| 6 | Wrangle action refs in examples/docs | `*/README.md` | release tag `@vX.Y.Z` |
| 7 | pip dev/CI tools | `tools/{zizmor,wrangle-shell-lint}/requirements.txt` | `==ver --hash=sha256:` |
| 8 | Script-installed release binaries | `tools/{osv,syft}/install.sh` | `VERSION="${1:-X}"` default |
| 9 | Dockerfile-installed tools | `test/Dockerfile` (actionlint, Go, govulncheck) | ARG + hardcoded SHA-256 / `go install` |
| 10 | apt packages | `test/Dockerfile` (bats, shellcheck) | unpinned |
| 11 | Test base image | `test/Dockerfile` | OCI `@sha256:` digest |

> **Incoming with the Ampel verify integration ([#247](https://github.com/TomHennen/wrangle/issues/247)):**
> a script-installed `ampel` binary verified via `gh attestation verify` (SLSA
> provenance tier — slsa-verifier deliberately not used, as it doesn't accept
> ampel's `attest-build-provenance` bundle shape), and a new category — **Ampel
> policy content**, referenced as SHA-pinned `git+https://…@<commit>` VCS
> locators in `policies/*.hjson` and divergence-guarded by the policy test
> harness. Fold these into the tables above when that work lands.

## How integrity is verified

Verification follows the tier ladder in
[`CLAUDE.md` § Install method and verification](CLAUDE.md) — that file is the
single source for the ladder; this section maps each category onto it.

| Category | Tier | Mechanism |
|---|---|---|
| osv-scanner | **SLSA provenance** (top) | `wrangle_verify_provenance` → `slsa-verifier verify-artifact` against OSV's published provenance |
| SLSA generator workflows | **SLSA provenance** (generator) | OIDC identity verification (tag-bound) |
| syft | **Sigstore signature** | `cosign verify-blob` of `checksums.txt`, then SHA-256 of the tarball against the cosign-trusted checksums (Anchore ships no provenance — documented in `tools/syft/install.sh`) |
| pip tools (zizmor, ast-grep-cli) | **hash-pinned package manager** | `pip install --require-hashes` |
| actionlint, Go (test image) | **hardcoded SHA-256** | `sha256sum -c` against ARG-pinned checksums |
| govulncheck | Go sumdb (first-seen immutability, *not* publisher authenticity) | `go install` with `GOPROXY`/`GOSUMDB` asserted |
| Actions (third-party + self-refs) | commit-SHA immutability | SHA pin; `zizmor` `unpinned-uses` + `impostor-commit` enforce live (`make zizmor`, CI); `test.bats` assert `@[0-9a-f]{40}` |
| base image | OCI digest | `@sha256:` digest pins layer content and anchors the otherwise-unpinned apt packages |

All custom install scripts abort on verification failure and **never** fall back
to a weaker tier.

## How upgrades happen

Two automated tracks; the rest manual.

**Automated — Dependabot** (`.github/dependabot.yml`): weekly, capped PR count,
**no auto-merge**, with a default cooldown that implements CLAUDE.md's "adopt
after a delay" rule.
- `github-actions` over the repo — every **third-party** action SHA; new
  composites are auto-discovered by the glob. Dependabot does **not** open PRs
  for wrangle's own `TomHennen/wrangle/…@<sha>` self-references — those go through
  `bump-action-pins` below.
- `pip` over `/tools/**` — bumps `requirements.txt` version **and** hashes
  atomically.

**Semi-automated — `make bump-action-pins`** (`tools/bump_action_pins.sh`):
rewrites every `TomHennen/wrangle/…@<sha>` self-reference **in
`.github/workflows/`** to a target SHA and refreshes the `# main DATE` comment.
Run by a human after merging a PR that changes a referenced composite. Its glob
is **non-recursive over `.github/workflows/`**, so self-refs inside `actions/`
(e.g. `actions/scan/action.yml`) are **not** covered — see Drift.

**Manual** (hand-edit, no automation): script-installed binary versions
(`tools/*/install.sh`); Dockerfile tools (actionlint, Go, govulncheck) and the
base-image digest (no `docker` ecosystem is declared, and it would only touch
`FROM`, never in-`RUN` `curl` installs); the SLSA generator tag; example/doc
tags; and `compute_slsa_source.yml`'s upstream-`main` SHA.

> `make update-tool` is currently a **non-functional stub** — tool-binary
> upgrades are manual today. (Where docs describe it as a working helper, that is
> doc drift to correct.)

## Drift risks and mitigations

CLAUDE.md § "Pins drift across files" requires every pin that lives in more than
one file to be **single-sourced** *or* guarded by a **divergence-fail test**.
Current structural status (specific live instances are tracked as issues, not
pinned here, since exact versions churn):

| Pin class | Status |
|---|---|
| Same third-party action pinned in several files (e.g. the artifact-upload and cosign-installer actions) | Can drift transiently because Dependabot opens **per-directory** PRs that land asynchronously. A *hard* divergence test would fight that window — consolidating the duplicated steps into a shared composite is the durable fix. |
| The `slsa-verifier` installer action across multiple workflow files | Consistent today but **unguarded** (the self-ref bumper doesn't touch it). Add a divergence-fail `bats` test (stable literal — safe to hard-guard). |
| `govulncheck` in `test/Dockerfile` ↔ the go checks action default | **Unguarded** — the exact pair CLAUDE.md names; the Dockerfile comment asserts parity but nothing enforces it. Add a divergence-fail test. |
| Wrangle self-refs **outside** `.github/workflows/` (e.g. `actions/scan/action.yml`) | **No updater owns them** — outside the `bump_action_pins.sh` glob and tagless for Dependabot, so they go stale. Sharpest live gap; extend the bumper to cover `actions/`. |
| Version comment vs SHA (`# vX`) | Unverified — a wrong comment passes `actionlint`/`zizmor`. Treated as decorative; the SHA is the contract. |

Precedent to build on: the `pip` deps are single-sourced; `zizmor`'s
requirements-vs-`action.yml` default has a `bats` divergence guard. Mirror that
pattern to close the unguarded pairs above.

## For reviewers

When reviewing a dependency change, check:

1. **Format.** Third-party action → `@<40-hex> # vX`. Self-ref → `@<sha> # main DATE`.
   No bare `@main` anywhere (incl. examples/docs). The SLSA generator tag is the
   only sanctioned tag-only ref and must keep its `# zizmor: ignore` justification.
2. **Tier not weakened.** A change must not drop to a weaker integrity tier
   without a documented reason that the stronger tier is genuinely unavailable
   upstream (per the decision tree). Convenience is not a reason.
3. **No undocumented drift.** If a pin literal you touched also appears elsewhere
   (`grep` it), the copies must move together or a divergence guard must exist.
   Watch the known unguarded pairs (`slsa-verifier`, `govulncheck`).
4. **Self-refs are fresh.** After merging a composite change, confirm
   `make bump-action-pins` ran; remember it does **not** cover `actions/` self-refs.
5. **No auto-merge.** Dependency-update PRs wait out the cooldown and get a human review.

## Tracking items

[#264](https://github.com/TomHennen/wrangle/issues/264) (centralized `tools.lock`
+ freshness automation for the manual binary surface),
[#277](https://github.com/TomHennen/wrangle/issues/277) (install-method audit),
[#136](https://github.com/TomHennen/wrangle/issues/136) (`$\{{}}` same-repo
syntax — simplifies categories 3–4),
[#218](https://github.com/TomHennen/wrangle/issues/218) (self-ref impostor-commit
/ advisory-check gap),
[#247](https://github.com/TomHennen/wrangle/issues/247) (Ampel verify integration
— adds the gh-attestation tier and the policy-content category).
