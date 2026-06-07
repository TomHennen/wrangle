# Unified metadata layout (data contract)

The on-disk shape downstream tooling, policy engines, and audit dashboards walk;
the filenames here ARE the interface. Parts of this layout are documented ahead
of implementation — see "Status: documented vs. emitted today" at the bottom for
which paths a tool can rely on now.

---

Every build type publishes its outputs to **two complementary places**:

1. **The ecosystem-native location** consumers already expect (PyPI release
   attestations, GHCR image attestations, GitHub release assets). A **partial**
   view — only what the ecosystem has standardized.
2. **A consistent unified wrangle location** for cross-ecosystem tooling, policy,
   and audit. The **complete** view — same schema regardless of build type, so a
   tool spanning N ecosystems reads one layout instead of N.

Both layers always exist for every build type; they are not either-or.

## Contract (adopter- and downstream-facing; stable)

| | |
|---|---|
| **Unified dir** | `metadata/<type>/<shortname>/` in the runner workspace |
| **`<type>`** | the build type — `container`, `python`, `npm`, … |
| **`<shortname>`** | path-derived package name, `/` → `_` (so multiple builds in one workflow don't collide) |
| **Workspace-path output** | composite action exposes the dir as the `metadata-dir` output for direct callers |
| **Artifact name** | reusable workflow uploads the dir contents as workflow artifact `<type>-metadata-<shortname>`, exposed as the `metadata-artifact-name` output |
| **Artifact shape** | `upload-artifact` zips the *contents* of the leaf dir; a downstream `download-artifact … path: metadata/` recovers files at the top level — the `<type>/<shortname>/` levels are NOT preserved inside the zip |

Provenance (`.intoto.jsonl`) is a **separate** SLSA-generator artifact with its own
`provenance-artifact-name` output — it is not uploaded inside the metadata
artifact. See drift note 4.

## Directory structure (reference)

```
metadata/<type>/<shortname>/
├── sbom.spdx.json                     # SPDX SBOM (build types with dependencies)
├── <type>-<shortname>.intoto.jsonl    # SLSA provenance — see drift note 4 (separate artifact today)
├── summary.md                         # human-readable build summary — see drift note 2 (NOT a file today)
├── scan/
│   ├── osv.sarif                      # SBOM vuln scan — see drift note 3 (not produced in-build today)
│   └── zizmor.sarif                   # action-specific scans where applicable
└── build-info.json                    # type-specific structured metadata — see drift note 1 (absent today)
```

Build types use the components that apply to them — not every type produces every
file. The point of the contract is that any tool walking
`metadata/<type>/<shortname>/` knows where to look.

**This block is hand-maintained and has drifted from what the build actions emit
(notes 1–4). It SHOULD be made drift-proof** — a CI check that diffs the
documented filenames against the real output of each `build/actions/<type>/`
(e.g. a fixture build whose emitted tree is asserted file-by-file), rather than
the current text-greps of `action.yml`. Today nothing asserts the *contents* of
the metadata dir; the layout is `⚠ prose load-bearing`.

## Invariants

Each invariant is followed by the check that enforces it, or `⚠ prose
load-bearing` where nothing mechanical does. Note: every "layout" test found is a
**text-grep of `action.yml`** for a path fragment — it asserts the source
contains a string, NOT that the build emits the file. Those are marked *weak*.

- **Unified dir is `metadata/<type>/<shortname>/`** — the type-namespaced path is
  written by the composite. → *weak* `build/actions/container/test.bats`
  "container: action.yml writes SBOM under metadata/container/<shortname>/"
  (greps `action.yml` for `metadata/container/`); same shape for
  `metadata/python/` / `metadata/npm/` in the respective `extract_metadata.sh`.
- **`<shortname>` is the package path with `/` → `_`** — collision-avoidance for
  multiple builds in one workflow. → `build/actions/container/test.bats`
  "container: validate_inputs.sh writes path/imagename/shortname to
  GITHUB_OUTPUT" (asserts `shortname=pkg_foo` for input `pkg/foo`).
- **Composite exposes the dir as `metadata-dir`** — direct callers read the
  workspace-relative path without reconstructing the convention. → *weak*
  `build/actions/container/test.bats` "container: action.yml exposes metadata-dir
  output"; "container: composite metadata-dir output sources from meta_dir step".
- **Artifact is `<type>-metadata-<shortname>`** — downstream `download-artifact`
  uses the name without hardcoding it. → *weak*
  `build/actions/container/test.bats` "container: action.yml uploads
  container-metadata-<shortname> artifact"; reusable-workflow side
  `build/actions/python/test.bats` "python: workflow uploads SBOM/metadata, not
  just dist" and `build/actions/npm/test.bats` "npm: workflow uploads
  SBOM/metadata, not just dist".
- **Artifact name namespaced by shortname** — two builds in one run don't collide
  on a shared artifact name (`download-artifact` picks non-deterministically). →
  *weak* `build/actions/python/test.bats` "python: workflow namespaces artifacts
  by shortname"; `build/actions/npm/test.bats` "npm: workflow namespaces
  artifacts by shortname".
- **Provenance filename namespaced `<type>-<shortname>.intoto.jsonl`** — wrangle
  passes `provenance-name` to the SLSA generator so multiple builds don't collide
  on the default `multiple.intoto.jsonl`; a verify job downloading the wrong
  build's provenance fails with a confusing hash mismatch. This one is enforced
  against real workflow wiring, not just a path string. → `build/actions/npm/test.bats`
  "npm: provenance job passes namespaced provenance-name to SLSA generator";
  `build/actions/python/test.bats` "python: provenance job passes namespaced
  provenance-name to SLSA generator".
- **`sbom.spdx.json` is the SBOM filename** — the literal a downstream tool opens.
  → `⚠ prose load-bearing`. Build tests assert only that the action *generates an
  SBOM* (`build/actions/python/test.bats` "python: action.yml generates SBOM",
  greps for `spdx-json|sbom`; `build/actions/npm/test.bats` "npm: action.yml
  generates SBOM via syft (SPDX)") — none assert the emitted leaf is named
  `sbom.spdx.json`.
- **Tree contents (`scan/`, `summary.md`, `build-info.json`, file naming)** —
  → `⚠ prose load-bearing`, and three of these have **drifted** (notes 1–3). No
  test reads the metadata dir's contents.

## Status: documented vs. emitted today

The layout above is partly aspirational — several documented paths are produced
by no build action yet. Until a CI check diffs this contract against a real
build's output, treat these as not-yet-reliable:

1. **`build-info.json`** — not written anywhere in the repo today.
2. **`summary.md`** — the human summary goes to `$GITHUB_STEP_SUMMARY` (container
   via `lib/format_sarif_summary.sh`; python/npm via `generate_summary.sh`), not
   to a `summary.md` file in the dir.
3. **`scan/<tool>.sarif`** — not emitted in-build (no `build/actions/*/action.yml`
   runs a scanner). The SARIF readers (`lib/check_results.sh`, `log_findings.sh`)
   expect `<metadata_dir>/<tool>/output.sarif`, not `scan/<tool>.sarif` — so the
   documented path is wrong on both nesting and filename.
4. **`.intoto.jsonl`** — a separate SLSA-generator artifact uploaded under its own
   name, adjacent to the metadata upload, not nested inside this tree.
5. **Go** — split across `build/actions/go/{verify,checks,release}/` with no
   unified `metadata-dir`, so it does not yet satisfy "every build type publishes
   the same set."
