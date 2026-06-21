# Wrangle FAQ

Short answers to questions adopters ask. For mechanism and contracts, each
answer links to the source of truth — start with [`SPEC.md`](SPEC.md) and the
[verification guide](verifying_artifacts.md).

## What attacks does wrangle help with?

The [threat coverage map](threat_coverage.md) maps wrangle's controls to real
software supply-chain incidents — what each one prevents, warns on, or detects,
where its limits are, and a frank list of the attacks wrangle does little
against. Disagree with a mapping, or know one we're missing? We'd love to hear
it.

## How should I pin wrangle's reusable workflows?

Pin by release **tag** (`@vX.Y.Z`), with an inline zizmor exception on that one
line:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.2 # zizmor: ignore[unpinned-uses] - immutable
```

wrangle's release tags are
[immutable](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
— a published `vX.Y.Z` is locked to its commit and can't be moved or deleted. A
tag is legible (you see the version), Dependabot-tracked, and its verify
identity (`@refs/tags/vX.Y.Z`) is the one wrangle's consumer policy and the
[verification guide](verifying_artifacts.md)'s `cosign` command require. The
inline ignore is needed because wrangle's bundled zizmor scan flags any
tag-pinned `uses:` and can't tell the tag is immutable.

Your **other** actions still pin by SHA — they aren't immutable.

### Why a tag and not a SHA?

The VSA's keyless signing certificate records the ref you pinned wrangle at. A
tag pin yields identity `@refs/tags/vX.Y.Z`; a SHA pin yields a bare `@<sha>`.
wrangle's consumer policy requires the tag form, so a SHA-pinned build produces
a VSA that fails both your own `verify-vsa` publish gate and any downstream
consumer running wrangle's standard policy. The build still runs under a SHA pin
— it just won't verify. This is a deliberate consumer-provenance guarantee: a
consumer learns the artifact was built with an official wrangle release, not a
cherry-picked commit.

### How does my pin affect verification?

Your verifier's expected identity must match **the release tag you pinned** —
wrangle's keyless VSA records the ref you invoked it at in the signing
certificate.

- A **tag** pin yields identity `…build_and_publish_<type>.yml@refs/tags/vX.Y.Z`
  — what both the [verification guide](verifying_artifacts.md)'s `cosign`
  command and the **`ampel verify`** consumer policy require.
- A **SHA** pin yields `…@<sha>`, which the consumer policy rejects; the VSA
  won't verify.

Requiring a release tag doesn't stop you pinning an old, possibly vulnerable
release — any `vX.Y.Z` matches. It raises the verification floor from "any
commit" to "any release," nothing more.

### Which version should I pin?

The latest [release](https://github.com/TomHennen/wrangle/releases) tag.
Dependabot and the examples under
[`gh_workflow_examples/`](../gh_workflow_examples/) track the current release.

## I'm on a private repo without Advanced Security — which scan tools work?

Most of the default `scan-tools` work as-is. The SARIF upload to the Security
tab needs code scanning (GitHub Advanced Security), but it's additive — when
it's unavailable the tools still gate on findings via the step summary
(see [`SPEC.md`](SPEC.md)). `scorecard` is already `:info` and push-only.

The one default that hard-fails is **`dependency-review`**: it calls GitHub's
dependency-graph API, which a private repo only exposes with Advanced Security,
so without it the call returns 403 and the scan fails closed. Drop it from
`scan-tools` (or set `dependency-review:info`) until you enable Advanced
Security or the repo goes public, then promote it back to blocking:

```yaml
scan-tools: "osv zizmor scorecard:info wrangle-lint"
```

`osv`, `zizmor`, and `wrangle-lint` stay blocking on real findings.

## An OSV finding I can't fix yet is blocking the release — what do I do?

The default policy gates on a clean OSV scan, so an unfixed advisory blocks the
release. To waive one you can't fix yet, suppress it in
[`osv-scanner.toml`](https://google.github.io/osv-scanner/configuration/) with a
`reason` — osv-scanner applies that config natively, so the advisory is excluded
from the scan result. Keep the reason honest and drop the suppression once a fix
ships.

## Why these tools and not others?

They seemed good for the job. wrangle isn't a ranking of every scanner or
policy engine, it's a working composition of solid, open-source ones.

The choice isn't load-bearing: tools can be replaced, and new ones added as
they come up. That's the point of the framework, not a claim that today's
lineup is the only right one.

## Doesn't depending on wrangle just add another supply chain risk?

Yes, it does. Using wrangle's reusable workflow means trusting wrangle, the
same as any action you pull in. And right now wrangle is one person's hobby
project with no external security review, so the honest answer is: probably
don't depend on it yet.

## Why GitHub Actions only?

You have to start somewhere, and this is where most developers already are, and
where a lot of the recent supply chain incidents have landed. Walk, then run.
Other CI systems could follow if the idea proves out.

## Who are you and why did you do this?

I'm a software engineer who's worked in supply chain security for quite a while.
This an idea I've had stuck in my head and decided to pursue it as a hobby
project and a way to get more hands on experience with some of the new tools I
don't get to use at my day job.
