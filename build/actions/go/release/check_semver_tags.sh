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
#
# Fail-open rationale: this is a heuristic pre-flight. False positives
# are easy to construct (e.g. monorepo tag-prefix layouts where tags
# look like `mymodule/v1.2.3`, calendar versioning that happens to
# resolve via a custom template, brand-new repos mid-bootstrap). Gating
# a release on guesswork would be worse than warning and letting
# goreleaser surface its own native error if the template actually
# fails. Do not "upgrade" this to a hard gate without revisiting that
# tradeoff.
#
# Usage: check_semver_tags.sh [<input-path>]
#   <input-path> is the adopter's goreleaser project dir (composite
#   action's `path` input). Used only to point the warning at the
#   right .goreleaser.yml file; tag discovery is repo-wide and not
#   scoped to the subdirectory.

set -euo pipefail
set -f  # processes external arguments (git tag names) — disable globbing per CLAUDE.md

input_path="${1:-.}"
# Display path for the warning message — strip trailing slash and a
# leading "./" so "./" / "." both render as "." and "cmd/foo/" as
# "cmd/foo". Cosmetic; tag discovery is repo-wide regardless.
display_path="${input_path%/}"
display_path="${display_path#./}"
[[ -z "$display_path" ]] && display_path="."

semver_tag=$(git describe --tags --match "v[0-9]*" --abbrev=0 2>/dev/null || true)
if [[ -n "$semver_tag" ]]; then
    exit 0
fi

# Monorepo tag-prefix layout (goreleaser's `monorepo.tag_prefix:`):
# release tags look like `<prefix>/v1.2.3`, where the prefix names a
# module path. Those tags do not start with `v` so the `v[0-9]*` match
# above misses them — but goreleaser strips the prefix internally and
# resolves .Version correctly, so the user's setup is fine. Suppress
# the warning when any tag matches the monorepo shape.
monorepo_tag=$(git tag --list '*/v[0-9]*' | head -1)
if [[ -n "$monorepo_tag" ]]; then
    exit 0
fi

# No semver tag reachable. Capture the tag list once to keep the
# count/sample views consistent (a concurrent tag mutation between
# separate `git tag` calls could otherwise produce a count that
# disagrees with the sample) and to avoid the SIGPIPE-on-`head`
# subtlety under strict `set -o pipefail`.
mapfile -t all_tags < <(git tag --list)
tag_count=${#all_tags[@]}

if (( tag_count == 0 )); then
    printf '::notice title=No git tags::No git tags found. Goreleaser will use "0.0.0" for .Version in templates. Push a v0.0.0 tag if you want meaningful version numbers in artifact filenames.\n'
else
    # Cap the tag list at 5 to avoid overflowing GitHub Actions' 4096-char
    # annotation budget on repos with hundreds of tags. Show a "(and N
    # more)" suffix when truncated so the adopter knows what they're
    # missing.
    sample_tags="${all_tags[*]:0:5}"
    suffix=""
    if (( tag_count > 5 )); then
        suffix=" (and $((tag_count - 5)) more)"
    fi
    printf '::warning title=No semver tags::Non-semver tags found (%s%s) but no v* semver tag. Goreleaser .Version will not resolve to a valid semver string. Snapshot builds will fail if %s/.goreleaser.yml (key: snapshot.version_template) uses incpatch / incminor / incmajor. Use a commit-hash-based template (e.g. "{{ .ShortCommit }}-snapshot") or push a v0.0.0 tag to establish a semver baseline. Monorepo users with goreleaser monorepo.tag_prefix tags (e.g. mymodule/v1.2.3) can ignore this warning.\n' "${sample_tags}" "${suffix}" "${display_path}"
fi
