#!/usr/bin/env bats

# Unit tests for tools/check_catalog_provenance_freshness.sh — the provenance
# "built-from-current-source" gate. The build commit comes from a signed SLSA
# provenance read via `gh attestation verify`; a fake `gh` on PATH returns a
# fixture provenance whose resolvedDependency names a caller-chosen commit, so
# the real jq extraction + git ancestry/diff logic runs against a real throwaway
# git repo without any live attestation API. The repo's HEAD and history stand
# in for the release checkout (fetch-depth: 0).

DIGEST="sha256:$(printf 'a%.0s' {1..64})"
CURATED="ghcr.io/tomhennen/wrangle/osv@$DIGEST"

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/check_catalog_provenance_freshness.sh"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }

    REPO="$BATS_TEST_TMPDIR/repo"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    # Catalog lives OUTSIDE the repo so the fixture's `git add -A` can't stage it
    # and drop it on a branch switch.
    CATALOG="$BATS_TEST_TMPDIR/catalog.json"
    mkdir -p "$BIN_DIR"
    # A retry must not stall the suite; the fixture is deterministic.
    export PATH="$BIN_DIR:$PATH" WRANGLE_RETRY_DELAY=0

    _init_repo
    _catalog "$CURATED"
    export WRANGLE_CATALOG="$CATALOG"
}

# _init_repo — a throwaway repo carrying the image's build inputs (the tool dir,
# lib/, tools/go.mod + go.sum). C1 is exported as the initial build commit.
_init_repo() {
    mkdir -p "$REPO/tools/osv" "$REPO/lib"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name test
    printf 'FROM scratch\n' > "$REPO/tools/osv/Dockerfile"
    printf 'echo hi\n' > "$REPO/lib/foo.sh"
    printf 'module wrangle/tools\n' > "$REPO/tools/go.mod"
    printf 'h1:abc\n' > "$REPO/tools/go.sum"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm c1
    C1="$(git -C "$REPO" rev-parse HEAD)"
    export C1
}

_commit() {  # _commit <relpath> <content> -> exports the new HEAD sha in $LAST
    printf '%s\n' "$2" > "$REPO/$1"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "edit $1"
    LAST="$(git -C "$REPO" rev-parse HEAD)"
    export LAST
}

_catalog() {
    cat > "$CATALOG" <<JSON
{"tools":{"osv":{"kind":"scan","delivery":"image","image":"$1","network":"egress"}}}
JSON
}

# install_gh — a fake `gh` returning a signed-provenance shape. SHIM_COMMIT is
# the build commit; SHIM_URI overrides the source repo; SHIM_COMMIT2 adds a
# second distinct commit (ambiguity); SHIM_GH_FAIL makes the read fail.
install_gh() {
    cat >"$BIN_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
[[ -n "${SHIM_GH_FAIL:-}" ]] && { printf 'gh: attestation backend unreachable\n' >&2; exit 1; }
uri="${SHIM_URI:-git+https://github.com/TomHennen/wrangle@refs/heads/main}"
deps='{"uri":"'"$uri"'","digest":{"gitCommit":"'"${SHIM_COMMIT:-}"'"}}'
[[ -n "${SHIM_COMMIT2:-}" ]] && deps="$deps"',{"uri":"'"$uri"'","digest":{"gitCommit":"'"$SHIM_COMMIT2"'"}}'
printf '[{"verificationResult":{"statement":{"predicateType":"https://slsa.dev/provenance/v1","predicate":{"buildDefinition":{"resolvedDependencies":['"$deps"']}}}}}]\n'
SHIM
    chmod +x "$BIN_DIR/gh"
}

@test "provenance freshness: image built from current source passes (exit 0)" {
    install_gh
    cd "$REPO"
    SHIM_COMMIT="$C1" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"built from current source"* ]]
}

@test "provenance freshness: a later change to the tool dir is stale (exit 1)" {
    install_gh
    _commit tools/osv/Dockerfile 'FROM scratch
RUN true'
    cd "$REPO"
    SHIM_COMMIT="$C1" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"source changed"* ]]
}

@test "provenance freshness: a later lib/ change is stale (exit 1)" {
    install_gh
    _commit lib/foo.sh 'echo changed'
    cd "$REPO"
    SHIM_COMMIT="$C1" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"source changed"* ]]
}

# The load-bearing gap the adoption-lag check cannot see: a go.mod-only tool
# version bump that never re-published the image.
@test "provenance freshness: a tools/go.mod bump with no republish is stale (exit 1)" {
    install_gh
    _commit tools/go.mod 'module wrangle/tools
require x v1.2.3'
    cd "$REPO"
    SHIM_COMMIT="$C1" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"source changed"* ]]
}

@test "provenance freshness: an unrelated later change is still fresh (exit 0)" {
    install_gh
    _commit README.md 'hello'
    cd "$REPO"
    SHIM_COMMIT="$C1" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"built from current source"* ]]
}

@test "provenance freshness: attestation backend unreachable is an env error (exit 2)" {
    install_gh
    cd "$REPO"
    SHIM_GH_FAIL=1 SHIM_COMMIT="$C1" run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not read build provenance"* ]]
}

@test "provenance freshness: provenance naming a non-wrangle repo binds no commit (exit 1)" {
    install_gh
    cd "$REPO"
    SHIM_URI="git+https://github.com/evil/fork@refs/heads/main" SHIM_COMMIT="$C1" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no single wrangle source commit"* ]]
}

@test "provenance freshness: two distinct wrangle commits are ambiguous (exit 1)" {
    install_gh
    _commit tools/osv/Dockerfile 'FROM scratch
RUN true'
    cd "$REPO"
    SHIM_COMMIT="$C1" SHIM_COMMIT2="$LAST" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no single wrangle source commit"* ]]
}

@test "provenance freshness: a build commit absent from history fails closed (exit 1)" {
    install_gh
    cd "$REPO"
    local absent; absent="$(printf 'f%.0s' {1..40})"
    SHIM_COMMIT="$absent" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"absent"* ]]
}

@test "provenance freshness: a non-ancestor build commit fails closed (exit 1)" {
    install_gh
    # A commit on a divergent branch, not reachable from HEAD.
    git -C "$REPO" checkout -q -b side "$C1"
    _commit tools/osv/Dockerfile 'side branch'
    local side="$LAST"
    git -C "$REPO" checkout -q -
    cd "$REPO"
    SHIM_COMMIT="$side" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not an ancestor"* ]]
}

@test "provenance freshness: a non-curated entry is skipped (exit 0)" {
    install_gh
    _catalog "registry.example.com/x/osv@$DIGEST"
    cd "$REPO"
    # gh failing proves the entry was never resolved.
    SHIM_GH_FAIL=1 run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"all 0 curated"* ]]
}

# Stale (1) must not be masked by another tool's backend error (2).
@test "provenance freshness: a stale image wins over a second tool's backend error (exit 1)" {
    # toolb's image dir does not exist; only its provenance read fails. toola is
    # stale. The fake gh fails only for toolb's image ref.
    mkdir -p "$REPO/tools/toola" "$REPO/tools/toolb"
    printf 'FROM scratch\n' > "$REPO/tools/toola/Dockerfile"
    printf 'FROM scratch\n' > "$REPO/tools/toolb/Dockerfile"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm tools
    local base; base="$(git -C "$REPO" rev-parse HEAD)"
    _commit tools/toola/Dockerfile 'FROM scratch
RUN true'  # toola now stale vs base
    cat > "$CATALOG" <<JSON
{"tools":{
  "toola":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/toola@$DIGEST"},
  "toolb":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/toolb@$DIGEST"}}}
JSON
    cat >"$BIN_DIR/gh" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in
  *toolb*) printf 'gh: backend unreachable\n' >&2; exit 1 ;;
esac; done
printf '[{"verificationResult":{"statement":{"predicateType":"https://slsa.dev/provenance/v1","predicate":{"buildDefinition":{"resolvedDependencies":[{"uri":"git+https://github.com/TomHennen/wrangle@refs/heads/main","digest":{"gitCommit":"$base"}}]}}}}}]\n'
SHIM
    chmod +x "$BIN_DIR/gh"
    cd "$REPO"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"source changed"* ]]
    [[ "$output" == *"could not read build provenance"* ]]
}

@test "provenance freshness: missing gh is an env error (exit 2)" {
    # A clean PATH with the coreutils the script needs to reach its tool guard,
    # but no gh — proving the guard, not a host gh leak, decides.
    local clean="$BATS_TEST_TMPDIR/clean"
    mkdir -p "$clean"
    for t in jq git bash dirname cat mktemp grep; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$clean/$t"
    done
    cd "$REPO"
    PATH="$clean" run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"gh and jq are required"* ]]
}
