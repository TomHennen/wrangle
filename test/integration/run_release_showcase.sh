#!/usr/bin/env bash
set -euo pipefail
set -f  # disable globbing — processes external input (version arg)

# run_release_showcase.sh — exercise a freshly cut wrangle release tag.
#
# Usage: run_release_showcase.sh <version>
#        run_release_showcase.sh --check-pin <version>
#
# The companion repo's showcase-curated.yml fires on `vX.Y.Z` tags and pins
# wrangle's reusable workflow at a literal release tag (a `uses:` ref cannot be
# an expression), so the companion pin must already name <version> — otherwise
# the run would exercise the previous release. --check-pin verifies only that,
# as a pre-tag precondition; the full form pushes the tag and reports the
# showcase verdict.
#
# The tag push is idempotent: an existing tag is watched rather than recreated,
# so the job can be re-run after a transient failure.
#
# Environment:
#   GH_TOKEN               any token; every read here is public companion data
#   COMPANION_PUSH_TOKEN   PAT with contents:write on the companion, used for the
#                          tag push alone
#   COMPANION_REPO         owner/repo of the companion (default: tomhennen/wrangle-test)
#
# Exit: 0 showcase passed (or the pin matches), 1 it did not, 2 bad usage.

COMPANION_REPO="${COMPANION_REPO:-tomhennen/wrangle-test}"
CURATED_WORKFLOW="showcase-curated.yml"
WRANGLE_USES_RE='TomHennen/wrangle/[^@[:space:]]+@[^[:space:]]+'
START_POLL_SECONDS="${WRANGLE_SHOWCASE_POLL_SECONDS:-15}"
START_POLL_ATTEMPTS="${WRANGLE_SHOWCASE_POLL_ATTEMPTS:-20}"
WATCH_INTERVAL_SECONDS="${WRANGLE_SHOWCASE_WATCH_INTERVAL:-30}"

die() { printf 'run_release_showcase: %s\n' "$1" >&2; exit 1; }

check_version() {
    if [[ ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'run_release_showcase: version must be vX.Y.Z, got %q\n' "$1" >&2
        exit 2
    fi
}

check_pin() {
    local version="$1" src use ref found=0
    src="$(gh api -H "Accept: application/vnd.github.raw" \
        "repos/${COMPANION_REPO}/contents/.github/workflows/${CURATED_WORKFLOW}")" \
        || die "could not read ${CURATED_WORKFLOW} from ${COMPANION_REPO}"
    while IFS= read -r use; do
        ref="${use##*@}"
        [[ "$ref" == "$version" ]] \
            || die "${COMPANION_REPO} ${CURATED_WORKFLOW} pins wrangle at ${ref}, not ${version} — bump it before cutting"
        found=1
    done < <(printf '%s\n' "$src" | grep -oE "$WRANGLE_USES_RE" || true)
    [[ "$found" -eq 1 ]] || die "no wrangle pin found in ${COMPANION_REPO} ${CURATED_WORKFLOW}"
    printf 'run_release_showcase: %s pins wrangle at %s\n' "$CURATED_WORKFLOW" "$version"
}

push_tag() {
    local version="$1" target
    if gh api "repos/${COMPANION_REPO}/git/ref/tags/${version}" >/dev/null 2>&1; then
        printf 'run_release_showcase: tag %s already on %s; watching its run\n' \
            "$version" "$COMPANION_REPO"
        return 0
    fi
    target="$(gh api "repos/${COMPANION_REPO}/git/ref/heads/main" --jq .object.sha)" \
        || die "could not resolve ${COMPANION_REPO} main HEAD"
    GH_TOKEN="$COMPANION_PUSH_TOKEN" gh api "repos/${COMPANION_REPO}/git/refs" \
        --method POST \
        --field "ref=refs/tags/${version}" \
        --field "sha=${target}" >/dev/null \
        || die "could not create tag ${version} on ${COMPANION_REPO}"
    printf 'run_release_showcase: created %s -> %s on %s\n' "$version" "$target" "$COMPANION_REPO"
}

# A tag push sets head_branch to the tag name, so --branch selects this run.
SHOWCASE_RUN_ID=""
SHOWCASE_RUN_URL=""
find_run() {
    local version="$1" run="" i
    for ((i = 0; i < START_POLL_ATTEMPTS; i++)); do
        run="$(gh run list --repo "$COMPANION_REPO" --workflow "$CURATED_WORKFLOW" \
            --branch "$version" --limit 1 --json databaseId,url \
            -q '.[0] | select(.databaseId) | "\(.databaseId) \(.url)"' 2>/dev/null || true)"
        [[ -n "$run" ]] && break
        sleep "$START_POLL_SECONDS"
    done
    [[ -n "$run" ]] || die "no ${CURATED_WORKFLOW} run appeared for ${version} on ${COMPANION_REPO}"
    SHOWCASE_RUN_ID="${run%% *}"
    SHOWCASE_RUN_URL="${run##* }"
}

main() {
    local version=""
    case "${1:-}" in
        --check-pin)
            version="${2:-}"
            [[ -n "$version" ]] || { printf 'Usage: run_release_showcase.sh --check-pin <version>\n' >&2; exit 2; }
            check_version "$version"
            check_pin "$version"
            return 0
            ;;
        -*) printf 'run_release_showcase: unknown flag: %s\n' "$1" >&2; exit 2 ;;
        "") printf 'Usage: run_release_showcase.sh <version>\n' >&2; exit 2 ;;
        *) version="$1" ;;
    esac

    check_version "$version"
    [[ -n "${COMPANION_PUSH_TOKEN:-}" ]] || {
        printf 'run_release_showcase: COMPANION_PUSH_TOKEN not set (need contents:write on %s)\n' \
            "$COMPANION_REPO" >&2
        exit 2
    }

    check_pin "$version"
    push_tag "$version"
    find_run "$version"

    printf 'run_release_showcase: watching run %s on %s\n' "$SHOWCASE_RUN_ID" "$COMPANION_REPO"
    if ! gh run watch "$SHOWCASE_RUN_ID" --repo "$COMPANION_REPO" \
        --interval "$WATCH_INTERVAL_SECONDS" --exit-status; then
        printf '::error::%s is published and its tag is immutable, but its showcase run did not pass: %s. The release stays published; ship the remedy in the next patch release.\n' \
            "$version" "$SHOWCASE_RUN_URL" >&2
        exit 1
    fi
    printf 'run_release_showcase: showcase passed for %s\n' "$version"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
