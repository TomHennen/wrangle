#!/usr/bin/env bash
# preflight_attestation.sh — refuse to attest a private repo. On a private
# personal repo GitHub's attestation store is unavailable, so attestation fails
# outright; on a private org repo it signs to the public Sigstore transparency
# log, leaking the repo's identity and build timing. Either way, fail closed and
# point the adopter at the unattested mode.
#
# Reads from the event context only (prep holds no token, makes no API call):
#   ATTESTATION    — caller's attest-and-verify input (enabled|disabled)
#   SHOULD_RELEASE — the gate's verdict (true on a release run)
#   VISIBILITY     — github.event.repository.visibility (public|private|internal,
#                    or empty when the event carries no repository object)
# Only `public` may attest; `private` and `internal` are non-public.

set -euo pipefail
set -f    # values come from event context — no globbing

# Accept only enabled|disabled. A typo must fail loudly rather than silently
# taking the attested path.
wrangle_validate_mode() {
    case "$1" in
        enabled|disabled) return 0 ;;
    esac
    printf '::error::wrangle: invalid attest-and-verify %q — expected "enabled" or "disabled".\n' "$1" >&2
    return 1
}

# Write should-attest to GITHUB_OUTPUT. It gates the attest/verify/publish wiring;
# a written `true` is only ever reached past the private-repo wall, so it is
# structurally fail-closed.
wrangle_emit_should_attest() {
    [[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'should-attest=%s\n' "$1" >> "$GITHUB_OUTPUT"
    return 0
}

# Emit the actionable private-repo refusal, covering both non-public cases.
wrangle_print_private_refusal() {
    printf '::error::wrangle can'\''t attest a private repo: the attestation store is unavailable on a private personal repo, and on a private org repo signing leaks this repo'\''s identity and build timing to the public Sigstore transparency log.\n' >&2
    printf '::error::Set attest-and-verify to disabled to publish an unattested build (no provenance or VSA).\n' >&2
    printf '::error::Full private-repo attestation is tracked in https://github.com/TomHennen/wrangle/issues/600.\n' >&2
}

# Decide whether this run attests, emit should-attest, and fail closed on a
# private repo. Inputs arrive as env vars (see the header).
wrangle_preflight_attestation() {
    local mode="${ATTESTATION:-enabled}"
    wrangle_validate_mode "$mode" || return 1

    # Only a release run that wants attestation can reach the private-repo wall.
    if [[ "${SHOULD_RELEASE:-false}" != "true" || "$mode" != "enabled" ]]; then
        wrangle_emit_should_attest false
        printf 'attest-and-verify=%s should-release=%s — attestation preflight passed.\n' "$mode" "${SHOULD_RELEASE:-false}"
        return 0
    fi

    if [[ "${VISIBILITY:-}" != "public" ]]; then
        wrangle_print_private_refusal
        return 1
    fi

    wrangle_emit_should_attest true
    printf 'attest-and-verify=enabled visibility=public — attestation preflight passed.\n'
}

main() {
    wrangle_preflight_attestation
}

# Run on direct execution; sourcing (the unit tests) exposes the helpers only.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
