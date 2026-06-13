# Wrangle FAQ

Short answers to questions adopters ask. For mechanism and contracts, each
answer links to the source of truth — start with [`SPEC.md`](SPEC.md) and the
[verification guide](verifying_artifacts.md).

## How should I pin wrangle's reusable workflows?

By **release tag**, with an inline zizmor exception on that one line:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.1 # zizmor: ignore[unpinned-uses] - immutable
```

wrangle's release tags are
[immutable](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases):
a published `vX.Y.Z` is locked to its commit and can never be moved or deleted.
So a tag pin carries the same integrity as a SHA, while staying readable and
matching the verification identity (below).

The one wrinkle: wrangle's bundled zizmor scan flags any tag-pinned `uses:`
(`unpinned-uses`) — it can't tell wrangle's tags are immutable. The inline
`# zizmor: ignore[unpinned-uses] - immutable` scopes that exception to the wrangle line.
**Your other actions still pin by SHA** — they aren't immutable.

### Why a tag and not a SHA?

Pinning third-party actions by SHA is the usual advice because **a tag can be
moved** — a compromised maintainer can repoint `v1` at malicious code and your
pin follows it. wrangle removes that risk at the source: its release tags are
immutable ([immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
plus a no-bypass tag ruleset), so a published `vX.Y.Z` is permanently bound to
one commit and can never be moved or deleted.

With the move-the-tag attack gone, a SHA buys no extra integrity here, while a
tag is more legible (you see the version), bumps cleanly (Dependabot tracks the
tag), and makes your `cosign` verify identity (`@refs/tags/vX.Y.Z`) match the
[verification guide](verifying_artifacts.md) with no edits. The only cost is the
one-line zizmor ignore — `unpinned-uses` can't tell the tag is immutable. A SHA
pin remains fully supported if you prefer it.

### Prefer a SHA pin?

That works too, and needs no ignore — `@<sha> # vX.Y.Z`, like any other
third-party action. Dependabot bumps the SHA and refreshes the comment on
wrangle's no-auto-merge cooldown (copy the
[`dependabot.yml`](../gh_workflow_examples/dependabot.yml) starter). The
tradeoff is ergonomic: SHA pins are opaque, and your `cosign` verification
identity becomes `@<sha>` instead of the tag.

### How does my pin affect verification?

Your verifier's expected identity must match **whatever you pinned** — wrangle's
keyless VSA records the ref you invoked it at in the signing certificate.

- A **tag** pin yields identity `…build_and_publish_<type>.yml@refs/tags/vX.Y.Z`
  — what the [verification guide](verifying_artifacts.md)'s `cosign` command
  already expects.
- A **SHA** pin yields `…@<sha>`; adjust the `cosign`
  `--certificate-identity-regexp` accordingly.
- The recommended **`ampel verify`** path matches either (its policy uses
  `…@.+`).

### Which version should I pin?

The latest [release](https://github.com/TomHennen/wrangle/releases) tag.
Dependabot and the examples under
[`gh_workflow_examples/`](../gh_workflow_examples/) track the current release.
