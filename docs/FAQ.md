# Wrangle FAQ

Short answers to questions adopters ask. For mechanism and contracts, each
answer links to the source of truth — start with [`SPEC.md`](SPEC.md) and the
[verification guide](verifying_artifacts.md).

## How should I pin wrangle's reusable workflows?

Either a release **tag** or a commit **SHA** — both are safe; the choice is
preference. wrangle's examples use a tag for legibility.

**Tag** (`@vX.Y.Z`), with an inline zizmor exception on that one line:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.1 # zizmor: ignore[unpinned-uses] - immutable
```

wrangle's release tags are
[immutable](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
— a published `vX.Y.Z` is locked to its commit and can't be moved or deleted. A
tag is legible (you see the version), Dependabot-tracked, and its verify
identity (`@refs/tags/vX.Y.Z`) is the one the
[verification guide](verifying_artifacts.md)'s `cosign` command shows by
default. The cost is the one-line ignore — wrangle's bundled zizmor scan flags
any tag-pinned `uses:` and can't tell the tag is immutable.

**SHA** (`@<sha> # vX.Y.Z`), like any other third-party action — no ignore needed:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@<sha> # v0.2.1
```

A SHA is immutable *by construction* (a content hash — no external assumption);
Dependabot bumps it and refreshes the comment. The cost is legibility (opaque)
and a verify identity of `@<sha>` (adjust the `cosign` regexp).

Either way, your **other** actions still pin by SHA — they aren't immutable.

### Tag or SHA — which?

In practice, equivalent. The honest difference is what each rests on: a SHA's
immutability is cryptographic and needs nothing external; a tag's depends on
wrangle keeping immutable-releases and the no-bypass ruleset enabled — a
GitHub-control-plane assumption a SHA doesn't carry (though a release published
while they're on stays immutable even if they're later disabled). Pick the tag
for legibility and a verify command that matches out of the box; pick the SHA
for the most self-contained integrity.

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
