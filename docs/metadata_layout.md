# Unified metadata layout

Every wrangle build publishes its outputs to two complementary places: the
**ecosystem-native** location consumers already expect (PyPI attestations,
GHCR image referrers, GitHub release assets, …) and one **unified wrangle
location** that carries the complete set in the same shape for every build
type. This page documents the unified location. For the design rationale —
why both layers exist and how the artifact maps to a directory — see
[docs/SPEC.md](SPEC.md).

## What's in the metadata artifact

Each build uploads the unified set as one workflow artifact named
`<type>-metadata-<sn>` (download by that name with `actions/download-artifact`,
or from the run's Actions page). Its contents:

```
sbom.spdx.json              # SPDX SBOM (build types that resolve dependencies)
scan/<tool>/output.sarif    # findings, one subdir per scan tool that ran
scan/<tool>/output.md       # human-readable version of the same
scan/govulncheck/govulncheck.json   # go only; native JSON, not SARIF
<artifact>.intoto.jsonl     # SLSA provenance + signed VSA, one per released
                            #   artifact (release runs only)
```

## Which `scan/` subdirs appear

`scan/` holds **a `scan/<tool>/` subdir for each tool that actually ran** —
not a fixed five. Which tools run is driven by the caller's `scan-tools`
input (default `osv zizmor scorecard:info dependency-review wrangle-lint`),
and two of the defaults are event-gated:

- **scorecard** runs on non-PR events only.
- **dependency-review** runs on pull requests only.

So a PR run and a tag/push run of the same project produce different
`scan/` subdirs. Setting `scan-tools` to a custom list (or the empty string
to disable scanning) changes the set accordingly. **go** builds additionally
get `scan/govulncheck/govulncheck.json` from the checks job.

## Naming

`<type>` is the build type (`go`, `python`, `npm`, `container`) and `<sn>` is
the path-derived shortname — the `path` input with `/` → `_` (`services/api`
→ `services_api`), so several builds in one workflow don't collide. For the
common single root build (`path: .`) the shortname is empty and the suffix is
dropped, so the names are just `<type>-metadata` (and `<type>-dist`). The
reusable workflow exposes the names as its `metadata-artifact-name` and
`dist-artifact-name` outputs, so adopters needn't hardcode them.

## Finding the artifacts in the GitHub UI

Click **Actions** → find your wrangle workflow → click the run → scroll to
**Artifacts**. The URL looks like
`https://github.com/<owner>/<repo>/actions/runs/<id>#artifacts`.
