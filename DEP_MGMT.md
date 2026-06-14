# Dependency management

wrangle's product is shell, but its real dependency surface is the **upstream
tools it pulls at install and build time** — the policy / scan / SBOM binaries it
runs and the GitHub Actions it composes. This file is the **authoritative**
strategy for how those are chosen, pinned, verified, and kept current; `CLAUDE.md`
carries the one-line rules and points here.

The goal is to declare tool versions in real package manifests:
`tools/<tool>/requirements.txt` for the pip dev tools (today), and a `tools/go.mod`
`tool` manifest for the Go tools (pending completion of #247), with per-tool
install scripts only for what no package manager ships.

## Choosing how to install a dependency

The dominant risk in practice isn't a forged download — it's **running something
stale** with a known CVE. So wrangle weights **freshness first**, as a deliberate
tradeoff: an automatically-patched install from a slightly-less-attested channel
beats a marginally-stronger one that a human has to remember to update.

Before anything else — **is the dependency worth trusting at all?** Provenance and
signatures prove a binary is authentically built from source repo X; they do
*not* prove X is benign. Vet the project first: who maintains it, how widely it's
used, its release history, and that the module/path is the canonical one (not a
typo-squat or fork).

Then:

```
What are you adding?

1. Installable from a package manager Dependabot supports
   (go install / pip / npm / cargo), from a reputable, canonical source?
     → USE THAT. Dependabot keeps it patched (after the cooldown) — the bigger
       real-world security win. This is the default.
         • Go tools     → a `tool` directive in tools/go.mod, installed with
                          `go install` / `go build` at the pinned version
                          (sum.golang.org pins the bytes; Dependabot bumps it).
         • Python tools → tools/<tool>/requirements.txt (==version + --hash),
                          a venv + `pip install --require-hashes` (Dependabot
                          bumps version and hashes together).

2. Not package-manager-installable, but the publisher ships SLSA provenance or a
   sigstore signature?
     → download the binary and verify it through lib/download_verify.sh
       (cosign today).
       Freshness is then MANUAL — flag it against the #264 automation.

3. Neither?
     → hardcoded SHA-256 from a trusted out-of-band source, pinned in the
       installer, with a comment explaining why nothing stronger exists.
       Last resort.
```

A GitHub Action (a `uses:` reference) is a separate case — see [Pinning](#pinning).

Keep the footprint minimal: the smallest tool that does the job (`unzip` over
`python3`, `jq` over a Python script); don't add a language runtime for a
one-liner.

## Integrity tiers

When you download-and-verify (branch 2/3 above), use the strongest tier the
publisher offers, and never drop to a weaker one **for convenience** — "we'd have
to install one more tool" is not a reason; "the stronger tier is genuinely
unavailable upstream" is (and the PR must say which):

> **SLSA provenance > GitHub release attestation > sigstore signature >
> hash-pinned package manager (lockfile, `--require-hashes`) >
> hardcoded SHA-256.**

This interacts with the freshness-first rule deliberately. A package manager sits
at the "hash-pinned" rung, but its **Dependabot auto-patching is what earns it the
default slot** — freshness is treated as part of the security posture, not just
convenience. And for a Go tool from its canonical module path, `go install`
(build-from-source, sum.golang.org, your own verified toolchain) is **not** a
meaningful downgrade from binary+provenance: there is no foreign prebuilt binary
to attest, and a compromise of the upstream repo would defeat build provenance
just the same. So `go install` is a first-class choice, not a fallback.

When installing Go tools via `go install`, assert `GOPROXY` and `GOSUMDB` at the
install site so sum-database verification can't be silently disabled by the
inherited environment — the action/CI sets them explicitly rather than trusting
whatever is already set.

## Pinning

| Dependency | Pin format |
|---|---|
| Third-party GitHub Action | `@<40-hex sha> # vX` |
| Wrangle self-ref in a reusable workflow | `@<sha> # main YYYY-MM-DD` |
| Wrangle composite → sibling composite | relative path `./actions/…` |
| Wrangle action in examples/docs | release tag **required**: `@vX.Y.Z # zizmor: ignore[unpinned-uses] - immutable` (tags are immutable; the ignore silences `unpinned-uses`, which can't tell). A SHA pin still builds but its VSA fails verification. |
| Go tool | `tool` directive + pinned `require` in `tools/go.mod` (+ `go.sum`) |
| Python tool | `==version --hash=sha256:` in `requirements.txt` |
| Binary with no package manager | version pinned in the install script |
| Container base image | OCI `@sha256:` digest |

`@main` MUST NOT appear in any `uses:` line, anywhere — including examples and docs.

## Keeping things current

- **Dependabot** (`.github/dependabot.yml`) — configure it for each ecosystem in
  use, weekly, no auto-merge, with a cooldown that implements the 7-day "adopt
  after a delay" rule. This automatic patching is *why* branch 1 is the default.
- **`make bump-action-pins`** rewrites wrangle's own self-references after a
  composite changes (it currently reaches only `.github/workflows/` — see #287).
- **Manual today:** the binary+provenance installs (branch 2) and the base-image
  digest. Automating that surface — ideally one mechanism that also covers
  wrangle's own self-references — is #264.

## Drift

A pin literal (version, SHA, checksum) that lives in more than one file must be
**single-sourced or guarded by a divergence-fail test** — never left to humans to
update in lockstep. The pip versions are single-sourced by `requirements.txt` (the Go tools
likewise, by `tools/go.mod`); the existing `tools/zizmor`
requirements↔`action.yml` `bats` guard is the pattern to copy for the rest. Known unguarded duplicates are tracked in #286.

## For reviewers

1. **Reputable?** Is the dependency itself worth trusting — maintained, adopted,
   on its canonical path? Verification proves *authenticity*, not *benignity*.
2. **Fresh?** Prefer a Dependabot-covered package manager. If it's a manual binary
   install, is that justified (no PM release, or a stronger tier genuinely needed)?
3. **Tier not weakened for convenience.**
4. **Pinned correctly** — `# vX` SHA for third-party actions, `# main DATE` for
   self-refs, no bare `@main`; a pinned version in the manifest or script.
5. **No undocumented drift** — a pin literal you touched that also appears
   elsewhere must move together or be guarded.
6. **No auto-merge** — dependency updates wait out the cooldown and get a human review.

## Tracking

#264 (automate the manual binary surface, ideally covering wrangle's own refs too),
#277 (install-method audit), #286 (divergence guards), #287 (self-ref bump scope),
#136 (`$/` same-repo syntax), #218 (self-ref impostor-commit gap),
#247 (Ampel verify — ships the verify stage; ampel/bnd install via the
`tools/go.mod` `go install` manifest, branch 1 / Dependabot-covered).
