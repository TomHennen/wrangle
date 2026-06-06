#!/bin/bash
# actions/verify_attestation/verify_attestation.sh — verify the GitHub-issued
# SLSA build provenance for one or more subjects and surface the load-bearing
# identities for inspection.
#
# `gh attestation verify --signer-workflow` is the enforcement: it fails closed
# unless the attestation was signed by wrangle's reusable build workflow (the
# job_workflow_ref that, run inside a reusable workflow, becomes both the
# Sigstore cert identity and the provenance builder.id). The identity banner is
# informational — it prints builder.id / buildType / signer / issuer / the
# name->digest subject set so a human (and the release log) can confirm the
# values match wrangle's, but the binding is the flag, not the print.
#
# Inputs arrive as environment variables: SUBJECT (an oci://<image>@sha256:...
# ref, or a path to a file or a directory of files), REPO (owner/repo where the
# attestation is stored), SIGNER_WORKFLOW (the reusable workflow that must have
# signed it), and the optional BUNDLE_PATH (the attest action's offline bundle,
# verified in-run without an API round-trip), PREDICATE_TYPE, and CHECKSUMS_PATH
# (when set, the subject list is the names in that sha256sum-format file resolved
# under SUBJECT — used where SUBJECT is a directory holding non-artifact files,
# e.g. goreleaser's dist/, that must not be attested/verified).
#
# When BUNDLE_PATH is set the binding is --signer-workflow alone: gh verifies the
# offline bundle's own Sigstore cert + Rekor proof, and --repo only scopes the
# (skipped) API lookup, so --repo is not part of the integrity decision here.
#
# The arg-builder stays pure (no side effects) so unit tests can assert the
# exact gh CLI shape offline; `main` runs the work on direct execution.

set -euo pipefail
set -f  # disable globbing — processes external input

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREDICATE_TYPE="${PREDICATE_TYPE:-https://slsa.dev/provenance/v1}"

# Build the `gh attestation verify` enforcement argument vector from the
# environment. One argument per line so callers (and tests) read it into an
# array with mapfile. --format json is appended at the call site.
wrangle_gh_verify_args() {
    local args=(attestation verify
        --repo="$REPO"
        --signer-workflow="$SIGNER_WORKFLOW"
        --predicate-type="$PREDICATE_TYPE")
    # Prefer the locally-emitted bundle: it verifies in the same run with no
    # dependence on the attestations API having propagated the new record.
    [[ -n "${BUNDLE_PATH:-}" ]] && args+=(--bundle="$BUNDLE_PATH")
    printf '%s\n' "${args[@]}"
}

# Print the identities the verify enforced, for the human visual check and the
# release log. Defensive `// "unknown"` fallbacks: the jq paths describe gh's
# current JSON shape, but a drift here must not turn a passing verification into
# a failed step — enforcement already happened via --signer-workflow.
wrangle_print_identities() {
    local subj="$1" json="$2"
    printf -- '--- verified provenance identity: %s ---\n' "$subj"
    printf 'builder.id:  %s\n' "$(jq -r 'first(.[].verificationResult.statement.predicate.runDetails.builder.id) // "unknown"' <<<"$json" 2>/dev/null || printf 'unknown')"
    printf 'buildType:   %s\n' "$(jq -r 'first(.[].verificationResult.statement.predicate.buildDefinition.buildType) // "unknown"' <<<"$json" 2>/dev/null || printf 'unknown')"
    printf 'signer SAN:  %s\n' "$(jq -r 'first(.[].verificationResult.signature.certificate.subjectAlternativeName) // "unknown"' <<<"$json" 2>/dev/null || printf 'unknown')"
    printf 'issuer:      %s\n' "$(jq -r 'first(.[].verificationResult.signature.certificate.issuer) // "unknown"' <<<"$json" 2>/dev/null || printf 'unknown')"
    # The name->digest subject set the attestation binds: what verification
    # actually matched the bytes against. `gh attestation verify` already failed
    # closed if the subject digest didn't match, so this is for the audit log.
    printf 'subjects:    %s\n' "$(jq -r '[first(.[].verificationResult.statement.subject)[] | "\(.name // "-")@sha256:\(.digest.sha256 // "unknown")"] | join(", ")' <<<"$json" 2>/dev/null || printf 'unknown')"
}

# Verify one subject, failing closed on a non-zero gh exit.
wrangle_verify_one() {
    local subj="$1" json err rc=0
    local -a args
    mapfile -t args < <(wrangle_gh_verify_args)
    err="$(mktemp)"
    # `--` ends option parsing so a subject can never be read as a gh flag.
    json="$(gh "${args[@]}" --format json -- "$subj" 2>"$err")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'wrangle: attestation verification FAILED for %s (exit %s)\n' "$subj" "$rc" >&2
        cat "$err" >&2
        rm -f "$err"
        return "$rc"
    fi
    rm -f "$err"
    wrangle_print_identities "$subj" "$json"
}

# Expand SUBJECT into the concrete list of things to verify. With CHECKSUMS_PATH
# set, the list is exactly the names in that sha256sum-format file resolved under
# SUBJECT — NOT a directory glob — so non-artifact files a directory may hold
# (goreleaser's artifacts.json/config.yaml/metadata.json, build subdirs) are
# neither attested nor verified. Otherwise: an oci:// ref is a single subject; a
# directory fans out to its files (find, not a glob, so `set -f` stays on); a
# plain path is one file.
wrangle_subjects() {
    if [[ -n "${CHECKSUMS_PATH:-}" ]]; then
        # checksums.txt lines are `<sha256>  <name>` (two-space separator);
        # split on the first two-space run so filenames with internal
        # whitespace survive, and prefix with the SUBJECT base dir.
        awk -v d="$SUBJECT/" 'NF > 0 { idx = index($0, "  "); if (idx > 0) print d substr($0, idx + 2) }' "$CHECKSUMS_PATH"
        return
    fi
    case "$SUBJECT" in
        oci://*) printf '%s\n' "$SUBJECT" ;;
        *)
            if [[ -d "$SUBJECT" ]]; then
                find "$SUBJECT" -maxdepth 1 -type f | sort
            else
                printf '%s\n' "$SUBJECT"
            fi
            ;;
    esac
}

wrangle_verify_attestation() {
    # shellcheck source=validate_verify_attestation_inputs.sh
    source "$DIR/validate_verify_attestation_inputs.sh"
    wrangle_validate_verify_attestation_inputs "$SUBJECT" "$REPO" \
        "$SIGNER_WORKFLOW" "${BUNDLE_PATH:-}" "$PREDICATE_TYPE" "${CHECKSUMS_PATH:-}"

    # Propagate a failed verification explicitly rather than leaning on set -e:
    # callers (and bats `run`) may have it disabled, and a swallowed failure
    # here would pass the release gate on an unverifiable artifact.
    local subj count=0
    while IFS= read -r subj; do
        [[ -z "$subj" ]] && continue
        wrangle_verify_one "$subj" || return $?
        count=$((count + 1))
    done < <(wrangle_subjects)

    # Fail closed: a SUBJECT that matched no files would verify nothing and
    # exit 0, silently turning the release gate into a no-op.
    if [[ "$count" -eq 0 ]]; then
        printf 'wrangle: no subjects to verify for "%s" — refusing to pass vacuously\n' "$SUBJECT" >&2
        return 1
    fi
}

main() {
    case "${1:-}" in
        run) wrangle_verify_attestation ;;
        *) printf 'Usage: %s run\n' "${0##*/}" >&2; return 2 ;;
    esac
}

# Run on direct execution; sourcing (the unit tests) exposes the helpers only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
