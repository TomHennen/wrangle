# Wrangle FAQ

Short answers to questions adopters ask. For mechanism and contracts, each
answer links to the source of truth — start with [`SPEC.md`](SPEC.md) and the
[verification guide](verifying_artifacts.md).

## How should I pin wrangle's reusable workflows?

Pin by release **tag** (`@vX.Y.Z`), with an inline zizmor exception on that one
line:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.1 # zizmor: ignore[unpinned-uses] - immutable
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

Your verifier's expected identity must match **whatever you pinned** — wrangle's
keyless VSA records the ref you invoked it at in the signing certificate.

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
