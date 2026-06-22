#!/usr/bin/env bash
# preflight_attestation.sh — refuse to attest a private repo. wrangle's
# attestation path persists to GitHub's attestation store and signs to the
# public Sigstore transparency log, leaking a private repo's identity and build
# timing; fail closed and direct the adopter to the unattested mode.
#
# Required env (set by prep's step that runs it):
#   ATTESTATION   — caller's attestation input (required|disabled)
#   SHOULD_RELEASE — the gate's verdict (true on a release run)
#   VISIBILITY    — github.event.repository.visibility (public|private|internal,
#                   or empty when the event carries no repository object)
#
# Privacy is read from the event context only — prep holds no token and makes no
# API call. Only `public` may attest; `private` and `internal` are non-public.

set -euo pipefail
set -f    # values come from event context — no globbing

ATTESTATION="${ATTESTATION:-required}"

# Reject anything but the two allowed values before any decision so a typo fails
# loudly rather than silently taking the attested path.
case "$ATTESTATION" in
    required|disabled) ;;
    *)
        printf '::error::wrangle: invalid attestation %q — expected "required" or "disabled".\n' "$ATTESTATION" >&2
        exit 1
        ;;
esac

# Only a release run that wants attestation can hit the private-repo wall.
if [[ "${SHOULD_RELEASE:-false}" != "true" || "$ATTESTATION" != "required" ]]; then
    printf 'attestation=%s should-release=%s — attestation preflight passed.\n' "$ATTESTATION" "${SHOULD_RELEASE:-false}"
    exit 0
fi

if [[ "${VISIBILITY:-}" != "public" ]]; then
    printf '::error::wrangle attestation is not supported on private repositories yet.\n' >&2
    printf '::error::It persists to GitHub'\''s attestation store and signs to the public Sigstore transparency log, which would leak this repo'\''s identity and build timing.\n' >&2
    printf '::error::Set the attestation input to disabled to publish an unattested build (no provenance or VSA).\n' >&2
    printf '::error::Full private-repo attestation is tracked in https://github.com/TomHennen/wrangle/issues/600.\n' >&2
    exit 1
fi

printf 'attestation=required visibility=public — attestation preflight passed.\n'
