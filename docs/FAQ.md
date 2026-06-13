# Wrangle FAQ

Short answers to questions adopters ask. For mechanism and contracts, each
answer links to the source of truth — start with [`SPEC.md`](SPEC.md) and the
[verification guide](verifying_artifacts.md).

## Why do the examples pin a release tag (`@vX.Y.Z`) instead of a commit SHA?

The usual advice is to SHA-pin third-party actions, because tags are mutable.
Wrangle's examples pin its *own* reusable workflows by **release tag** on
purpose, for two reasons:

- **Your verifier's identity has to match what you pinned.** Wrangle signs each
  VSA keylessly, and the Sigstore certificate records the ref you invoked
  wrangle at. The copy-paste `cosign` verify command in the
  [verification guide](verifying_artifacts.md) anchors the signer identity on
  `@refs/tags/v…`, so a tag pin makes that command work unedited. (The
  recommended `ampel` path accepts either — see the next question.)
- **A tag version-locks the whole tested release.** A reusable workflow resolves
  its internal action references at the ref you called it with, so `@v0.2.0`
  runs exactly the internal toolchain that release shipped — see
  [SPEC.md → Reusable Workflow Interface](SPEC.md#reusable-workflow-interface).

You don't trade away freshness: Dependabot bumps the tag for you (the
[`dependabot.yml`](../gh_workflow_examples/dependabot.yml) starter wires it),
on wrangle's no-auto-merge cooldown.

## Do I have to pin a tag for verification to work?

No. The recommended **`ampel verify`** path accepts a tag *or* a SHA — its
policy matches the signer identity as `…@.+`. Only the **`cosign`** fallback
command assumes a tag, and the [verification guide](verifying_artifacts.md)
tells you how to adjust the identity regexp if you pinned a SHA.

The rule underneath both: **your verifier's expected identity must match
whatever you actually pinned** — tag → `@refs/tags/vX.Y.Z`, SHA → `@<sha>`.
Pinning a tag just means the documented commands work as written.

## Aren't mutable tags a supply-chain risk?

A tag can be moved, so pinning one trusts wrangle's release process not to
repoint it. Two things bound the blast radius:

- Every artifact you consume is checked against a **wrangle-signed VSA that
  binds the signer identity and your source repo** — verification fails if the
  bytes, the signer, or the origin repo don't match (see the
  [verification guide](verifying_artifacts.md)).
- **Dependabot** moves your pin forward only to published releases, after
  wrangle's cooldown, with no auto-merge.

If you want the strongest pin, SHA-pin wrangle's workflow and adjust your verify
identity as described above — verification still works.

## Which version should I pin?

The latest [release tag](https://github.com/TomHennen/wrangle/releases). The
per-ecosystem READMEs under [`build/`](../build/) and the examples in
[`gh_workflow_examples/`](../gh_workflow_examples/) track the current release.
