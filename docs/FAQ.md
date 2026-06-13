# Wrangle FAQ

Short answers to questions adopters ask. For mechanism and contracts, each
answer links to the source of truth — start with [`SPEC.md`](SPEC.md) and the
[verification guide](verifying_artifacts.md).

## How should I pin wrangle's reusable workflows?

By **commit SHA, with the version in a trailing comment** — exactly like any
other third-party action:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@<sha> # v0.2.0
```

Two reasons:

- **A tag can be moved; a SHA can't** — the usual reason to pin any third-party
  action by digest.
- **wrangle's own scan would otherwise flag you.** A wrangle build type runs
  zizmor over your workflows, and zizmor's `unpinned-uses` flags a third-party
  action that isn't SHA-pinned. Pin a tag and your first run fails on the very
  line wrangle told you to add; pin the SHA and it's clean.

SHA pins are opaque and go stale, but Dependabot handles both — it bumps the SHA
and refreshes the `# vX.Y.Z` comment on wrangle's no-auto-merge cooldown (copy
the [`dependabot.yml`](../gh_workflow_examples/dependabot.yml) starter).

## Can I pin a `@vX.Y.Z` tag instead?

You can, but wrangle's bundled zizmor scan will flag it (`unpinned-uses`) because
a tag can be moved. Since you only call wrangle once, the simplest fix is an
inline ignore on that line:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0 # zizmor: ignore[unpinned-uses]
```

It scopes the exception to the wrangle line; your other actions still need a
SHA. (Once wrangle publishes immutable release tags and zizmor treats them as
pinned, tag pins will be clean with no ignore — tracked in
[#387](https://github.com/TomHennen/wrangle/issues/387), not done yet.)

## How does my pin affect verification?

Your verifier's expected identity must match **whatever you pinned** — wrangle's
keyless VSA records the ref you invoked it at in the signing certificate. With a
SHA pin the identity is `…build_and_publish_<type>.yml@<sha>`:

- The recommended **`ampel verify`** path needs no change — its policy matches
  the signer as `…@.+`.
- The **`cosign`** fallback's `--certificate-identity-regexp` must match your
  SHA (the [verification guide](verifying_artifacts.md) shows the form); a
  tag pin would instead match `@refs/tags/vX.Y.Z`.

## Which SHA should I pin?

The commit the latest [release](https://github.com/TomHennen/wrangle/releases)
tags, with that version in the comment. Dependabot and the examples under
[`gh_workflow_examples/`](../gh_workflow_examples/) track the current release.
