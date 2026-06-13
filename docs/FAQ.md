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

Three reasons, and the examples are pinned this way:

- **It's wrangle's own rule.** To your repo, `TomHennen/wrangle` is a third-party
  action, and wrangle's policy (and the wider GitHub Actions consensus) is that
  third-party actions are SHA-pinned because tags are mutable.
- **wrangle's own scan would otherwise flag you.** A wrangle build type runs
  zizmor over your workflows, and zizmor's `unpinned-uses` flags a third-party
  action that isn't SHA-pinned. Pin the SHA and your first run is clean; pin a
  tag and you'll get a finding on the very line wrangle told you to add.
- **You keep freshness.** Dependabot bumps the SHA and refreshes the `# vX.Y.Z`
  comment on wrangle's no-auto-merge cooldown — copy the
  [`dependabot.yml`](../gh_workflow_examples/dependabot.yml) starter.

## Can I pin a `@vX.Y.Z` tag instead?

You can, but wrangle's bundled zizmor scan will flag it (`unpinned-uses`) because
a tag can be moved. The principled way to keep a tag is a **scoped** policy in
your own `.github/zizmor.yml` — not a blanket disable:

```yaml
rules:
  unpinned-uses:
    config:
      policies:
        "TomHennen/wrangle/*": ref-pin   # trust wrangle's release tags
```

That exempts only wrangle's refs; your other actions still require a SHA. (Once
wrangle publishes immutable release tags and zizmor treats them as pinned, tag
pins will be clean by default — that work is tracked in
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
