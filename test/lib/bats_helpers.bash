# test/lib/bats_helpers.bash — shared bats helpers, pulled in with `load`.
# A sourced helper library: no shebang (it's loaded into a bats test, never
# executed on its own), so it carries no script preamble. Not a *.bats file, so
# the suite's glob doesn't run it as a test.

# in_ci: true under CI (CI/GITHUB_ACTIONS set). The single definition of
# "are we in CI" for test helpers — skip policy and preflight probes must
# agree on it.
in_ci() {
    [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]
}

# skip_or_fail <reason>: under CI the real binary + network are present, so a
# skip means the test silently degraded — fail instead. Locally skip, so
# sandboxed dev isn't blocked.
skip_or_fail() {
    if in_ci; then
        printf 'FATAL: %s (skip not allowed in CI)\n' "$1" >&2
        exit 1
    fi
    skip "$1"
}

# wrangle_image_build <cache-slug> <docker-build-arg>...
# Build a tool image, passing args after the slug verbatim to the builder.
# With WRANGLE_BUILDX_CACHE set (the dogfood workflow) it builds through a
# persistent buildx local layer cache so the from-source builds aren't
# recompiled every run; unset (local) it's a plain docker build.
wrangle_image_build() {
    local slug="$1"
    shift
    if [[ -n "${WRANGLE_BUILDX_CACHE:-}" ]]; then
        local dir="$WRANGLE_BUILDX_CACHE/$slug"
        docker buildx build --load -q \
            --cache-from "type=local,src=$dir" \
            --cache-to "type=local,dest=$dir,mode=max" \
            "$@" >/dev/null
    else
        docker build -q "$@" >/dev/null
    fi
}
