#!/usr/bin/env bash
# Warn when no semver tag is reachable from HEAD.
#
# Goreleaser derives .Version from the nearest tag matching v[0-9]*.
# Without one it falls back to the nearest non-semver tag, which breaks
# snapshot templates that call incpatch / incminor / incmajor. This
# script surfaces that condition as a GitHub Actions annotation before
# goreleaser runs, so adopters get a clear diagnostic rather than a
# cryptic "invalid semantic version" deep in goreleaser output.
#
# Always exits 0 — this is a warning, not a gate.

set -euo pipefail

semver_tag=$(git describe --tags --match "v[0-9]*" --abbrev=0 2>/dev/null || true)
if [[ -n "$semver_tag" ]]; then
    exit 0
fi

# No semver tag reachable. Check whether any tags exist at all.
first_tag=$(git tag --list | head -1)
if [[ -z "$first_tag" ]]; then
    printf '::notice title=No git tags::No git tags found. Goreleaser will use "0.0.0" for .Version in templates. Push a v0.0.0 tag if you want meaningful version numbers in artifact filenames.\n'
else
    all_tags=$(git tag --list | tr '\n' ' ')
    printf '::warning title=No semver tags::Non-semver tags found (%s) but no v* semver tag. Goreleaser .Version will not resolve to a valid semver string. Snapshot builds will fail if your .goreleaser.yml snapshot.version_template uses incpatch / incminor / incmajor. Use a commit-hash-based template (e.g. "{{ .ShortCommit }}-snapshot") or push a v0.0.0 tag to establish a semver baseline.\n' "${all_tags}"
fi
