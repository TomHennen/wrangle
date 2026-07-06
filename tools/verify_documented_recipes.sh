#!/usr/bin/env bash
# Run the artifact-verification recipes documented in docs/verifying_artifacts.md
# against real artifact coordinates, to prove those adopter commands still work.
#
# Anti-drift by construction: the recipes are not reimplemented here. Each fenced
# ```bash block is EXTRACTED from docs/verifying_artifacts.md at run time, its
# <placeholders> substituted from the flags, and the result executed verbatim.
# The checker therefore cannot diverge from the documented commands — a doc that
# stops working fails the run, and a doc whose placeholder set changes fails the
# substitution guard rather than running half-filled.
#
# A block is selected by a literal content signature that matches exactly one
# fenced block (zero or many => the doc drifted, hard error), and only the
# <placeholder> TEMPLATE blocks are targeted — the concrete worked examples
# (which carry no `<...>`) are never selected.
#
# Exit: 0 = every selected recipe verified; 1 = a recipe failed verification;
# 2 = usage / configuration / doc-drift error.
#
# Tooling: ampel and cosign are expected on PATH (the verify-showcase-recipes
# action installs them from tools/go.mod); jq and gh are assumed present. Only
# `gh attestation verify`, the `github:` collector, and the Sigstore/OCI reads
# are network-bound; because a documented recipe is one fenced block, retry is
# applied at block granularity (the idempotent fetch is retried alongside the
# verify — harmless). On exhausted retries the recipe FAILS; it never skips.
#
# Public ghcr images are assumed (no registry pull auth); the private-image doc
# path is out of scope. `gh attestation verify` needs GITHUB_TOKEN in the env.
set -euo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Overridable so the hermetic tests can point at drift fixtures.
DOC="${WRANGLE_RECIPES_DOC:-$REPO_ROOT/docs/verifying_artifacts.md}"

RETRY_MAX="${WRANGLE_RECIPE_RETRIES:-3}"
RETRY_DELAY="${WRANGLE_RECIPE_RETRY_DELAY:-5}"

# Coordinates (all default empty so `set -u` is safe before parsing).
FILE_PATH=""
BUNDLE_PATH=""
IMAGE_NAME=""
DIGEST=""
RESOURCE_URI=""
REPO=""
BUILD_TYPE=""
DO_PROVENANCE=0
DO_ATTESTATION_STORE=0
NON_STRICT="${WRANGLE_VSA_NON_STRICT:-0}"

# Substitution values (filled during dispatch).
ARTIFACT_NAME=""

PASS_COUNT=0
FAIL_COUNT=0

log()  { printf 'verify-recipes: %s\n' "$*"; }
die()  { printf 'verify-recipes: ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
    cat >&2 <<'EOF'
Usage: verify_documented_recipes.sh <coordinates>

  File artifact (Go / Python / npm):
    --file PATH --bundle PATH --resource-uri URI --repo ORG/REPO --type TYPE

  Container image:
    --image NAME --digest SHA256HEX --repo ORG/REPO

  Add-ons:
    --provenance            also run `gh attestation verify` (needs --file --repo --type)
    --attestation-store     also run the github: collector (needs --resource-uri --repo)
    --non-strict            relax to the non-strict policy/identity (or WRANGLE_VSA_NON_STRICT=1)

TYPE is one of: go python npm container.
EOF
    exit 2
}

# --- input validation (allowlists: these values are substituted into an executed
# --- shell block, so anything outside the charset is rejected up front) --------
_need()        { [[ -n "$2" ]] || die "$1 is required for this recipe"; }
_valid_repo()  { [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }
_valid_uri()   { [[ "$1" =~ ^[A-Za-z0-9._:/@+-]+$ ]]; }
_valid_digest(){ [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
_valid_type()  { [[ "$1" =~ ^(go|python|npm|container)$ ]]; }
_valid_image() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; }
_valid_name()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# --- doc extraction ------------------------------------------------------------
# Collect into the array named by $2 every fenced ```bash block whose text
# contains the literal substring $1. Pure bash (no awk) so block boundaries don't
# depend on the host awk's handling of NUL separators.
_collect_blocks() {
    local sig="$1"
    local -n _out="$2"
    _out=()
    local line blk="" inblk=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$inblk" -eq 0 ]]; then
            [[ "$line" == '```bash' ]] && { inblk=1; blk=""; }
        elif [[ "$line" == '```' ]]; then
            [[ "$blk" == *"$sig"* ]] && _out+=("$blk")
            inblk=0
        else
            blk+="$line"$'\n'
        fi
    done < "$DOC"
}

# Print THE single template block matching signature $1; a count other than one
# means docs/verifying_artifacts.md drifted from what this checker expects.
_select_block() {
    local sig="$1"
    local -a matches=()
    _collect_blocks "$sig" matches
    (( ${#matches[@]} == 1 )) \
        || die "expected exactly one doc block matching '$sig', found ${#matches[@]} — docs/verifying_artifacts.md drifted"
    printf '%s' "${matches[0]}"
}

# Substitute the documented placeholders in the block on $1, then fail if any
# `<...>` survives — a surviving placeholder is an un-mapped doc token, i.e.
# drift, and must break the run rather than execute a half-filled command.
_substitute() {
    local blk="$1"
    blk="${blk//"<your-org>/<your-repo>"/"$REPO"}"
    blk="${blk//"<owner>/<repo>"/"$REPO"}"
    blk="${blk//"<resourceUri from the table above>"/"$RESOURCE_URI"}"
    blk="${blk//"<artifact>"/"$ARTIFACT_NAME"}"
    blk="${blk//"<imagename>"/"$IMAGE_NAME"}"
    blk="${blk//"<digest>"/"$DIGEST"}"
    blk="${blk//"<type>"/"$BUILD_TYPE"}"
    if [[ "$NON_STRICT" == "1" ]]; then
        # The doc documents only the strict recipes; these two relaxations mirror
        # the actions/verify-vsa gate's WRANGLE_VSA_NON_STRICT fallback (any
        # wrangle build ref, not just release tags) for wrangle's own dogfood
        # builds, whose VSAs carry a bare @<sha> signer identity.
        local strict_policy='wrangle-vsa-consumer-v1.hjson'
        local strict_anchor='@refs/tags/v[0-9.]+$'
        blk="${blk//"$strict_policy"/wrangle-vsa-consumer-nonstrict-v1.hjson}"
        blk="${blk//"$strict_anchor"/@}"
    fi
    if [[ "$blk" =~ \<[^\>]+\> ]]; then
        die "unsubstituted placeholder ${BASH_REMATCH[0]} in recipe — the recipe map is out of date with docs/verifying_artifacts.md"
    fi
    printf '%s' "$blk"
}

# --- recipe execution ----------------------------------------------------------
# Run a selected+substituted block. Args: name signature retry(0|1).
# The block runs in a private temp CWD (blocks 7/8 both write vsa.intoto.jsonl),
# with `set -euo pipefail` prepended so a mid-block `jq -e`/pipeline failure
# fails the recipe closed. File-class inputs are staged under the doc's bare
# filenames (`<artifact>`, `<artifact>.intoto.jsonl`).
_run_recipe() {
    local name="$1" sig="$2" retry="$3"
    local blk work script attempt rc
    blk="$(_select_block "$sig")"
    blk="$(_substitute "$blk")"

    work="$(mktemp -d)"
    script="$work/recipe.sh"
    { printf 'set -euo pipefail\n'; printf '%s\n' "$blk"; } > "$script"
    if [[ -n "$FILE_PATH" ]]; then
        cp "$FILE_PATH" "$work/$ARTIFACT_NAME"
        [[ -z "$BUNDLE_PATH" ]] || cp "$BUNDLE_PATH" "$work/$ARTIFACT_NAME.intoto.jsonl"
    fi

    log "--- recipe: $name"
    attempt=0
    rc=0
    while : ; do
        attempt=$((attempt + 1))
        rc=0
        ( cd "$work" && bash "$script" ) || rc=$?
        [[ $rc -eq 0 ]] && break
        if [[ "$retry" != "1" || $attempt -ge $RETRY_MAX ]]; then break; fi
        log "recipe '$name' attempt $attempt/$RETRY_MAX failed (rc=$rc); retrying in ${RETRY_DELAY}s"
        sleep "$RETRY_DELAY"
    done
    rm -rf "$work"

    if [[ $rc -eq 0 ]]; then
        log "PASS: $name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        log "FAIL: $name (rc=$rc)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)              FILE_PATH="$2"; shift 2 ;;
            --bundle)            BUNDLE_PATH="$2"; shift 2 ;;
            --image)             IMAGE_NAME="$2"; shift 2 ;;
            --digest)            DIGEST="$2"; shift 2 ;;
            --resource-uri)      RESOURCE_URI="$2"; shift 2 ;;
            --repo)              REPO="$2"; shift 2 ;;
            --type)              BUILD_TYPE="$2"; shift 2 ;;
            --provenance)        DO_PROVENANCE=1; shift ;;
            --attestation-store) DO_ATTESTATION_STORE=1; shift ;;
            --non-strict)        NON_STRICT=1; shift ;;
            -h|--help)           usage ;;
            *) die "unknown argument: $1" ;;
        esac
    done
}

main() {
    parse_args "$@"

    local ran=0

    # File-artifact class: the ampel jsonl recipe, the cosign+jq fallback, and
    # the verifiedLevels read. Gated on --bundle (the class's unique input), so
    # a bare --file with --provenance drives only the provenance recipe.
    if [[ -n "$BUNDLE_PATH" ]]; then
        _need --file "$FILE_PATH"
        [[ -f "$FILE_PATH" ]]   || die "no such file: $FILE_PATH"
        [[ -f "$BUNDLE_PATH" ]] || die "no such bundle: $BUNDLE_PATH"
        ARTIFACT_NAME="$(basename "$FILE_PATH")"
        _valid_name "$ARTIFACT_NAME" || die "artifact filename has disallowed characters: $ARTIFACT_NAME"
        _need --resource-uri "$RESOURCE_URI"; _valid_uri "$RESOURCE_URI"  || die "bad --resource-uri: $RESOURCE_URI"
        _need --repo "$REPO";                 _valid_repo "$REPO"         || die "bad --repo: $REPO"
        _need --type "$BUILD_TYPE";           _valid_type "$BUILD_TYPE"   || die "bad --type: $BUILD_TYPE"

        _run_recipe "file VSA via ampel (jsonl collector)" '--collector jsonl:<artifact>' 1
        _run_recipe "file VSA via cosign + jq"             'sha256sum <artifact>'         1
        _run_recipe "verifiedLevels read (jq)"             '.predicate.verifiedLevels[]'  0
        ran=1
    fi

    # Container-image class: ampel oci collector + cosign download attestation.
    if [[ -n "$IMAGE_NAME" ]]; then
        _need --image "$IMAGE_NAME";  _valid_image "$IMAGE_NAME"  || die "bad --image: $IMAGE_NAME"
        _need --digest "$DIGEST";     _valid_digest "$DIGEST"     || die "bad --digest (want 64 hex, no sha256: prefix): $DIGEST"
        _need --repo "$REPO";         _valid_repo "$REPO"         || die "bad --repo: $REPO"

        _run_recipe "image VSA via ampel (oci collector)"      '--collector oci:'            1
        _run_recipe "image VSA via cosign download attestation" 'cosign download attestation' 1
        ran=1
    fi

    # By-digest read from the GitHub attestation store (any build type).
    if [[ "$DO_ATTESTATION_STORE" -eq 1 ]]; then
        _need --repo "$REPO";                 _valid_repo "$REPO"        || die "bad --repo: $REPO"
        _need --resource-uri "$RESOURCE_URI"; _valid_uri "$RESOURCE_URI" || die "bad --resource-uri: $RESOURCE_URI"
        if [[ -n "$FILE_PATH" ]]; then
            DIGEST="$(sha256sum "$FILE_PATH" | cut -d' ' -f1)"
        fi
        _need --digest "$DIGEST"; _valid_digest "$DIGEST" || die "attestation-store recipe needs a sha256 digest"
        _run_recipe "VSA via github: collector (attestation store)" '--collector github:' 1
        ran=1
    fi

    # Raw provenance via gh attestation verify (file build types).
    if [[ "$DO_PROVENANCE" -eq 1 ]]; then
        _need --file "$FILE_PATH"; [[ -f "$FILE_PATH" ]] || die "no such file: $FILE_PATH"
        ARTIFACT_NAME="$(basename "$FILE_PATH")"
        _valid_name "$ARTIFACT_NAME" || die "artifact filename has disallowed characters: $ARTIFACT_NAME"
        _need --repo "$REPO";       _valid_repo "$REPO"       || die "bad --repo: $REPO"
        _need --type "$BUILD_TYPE"; _valid_type "$BUILD_TYPE" || die "bad --type: $BUILD_TYPE"
        # Bundle not staged for this recipe, so clear it for _run_recipe's stager.
        BUNDLE_PATH=""
        _run_recipe "raw provenance via gh attestation verify" 'gh attestation verify' 1
        ran=1
    fi

    [[ "$ran" -eq 1 ]] || usage

    log "summary: $PASS_COUNT passed, $FAIL_COUNT failed"
    [[ "$FAIL_COUNT" -eq 0 ]] || exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
