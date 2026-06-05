#!/usr/bin/env bats

# Tests for actions/verify_attestation/verify_attestation.sh and its input
# validator.
#
# The arg-builder and subject-expansion functions are pure, so they're asserted
# offline. The end-to-end verify path is driven by a `gh` stub on PATH (the real
# `gh attestation verify` needs a live attestation + Sigstore, which no unit
# suite can produce on demand); `jq` is real, so the identity-extraction jq
# paths are exercised against a realistic gh JSON shape.
load "../../test/lib/bats_helpers"

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/verify_attestation.sh"
    VALIDATE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/validate_verify_attestation_inputs.sh"
    TEST_DIR="$(mktemp -d)"
    STUB_BIN="$TEST_DIR/bin"
    mkdir -p "$STUB_BIN"

    export SUBJECT="dist"
    export REPO="TomHennen/wrangle"
    export SIGNER_WORKFLOW="TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml"
    export BUNDLE_PATH=""
    export PREDICATE_TYPE="https://slsa.dev/provenance/v1"
    export CHECKSUMS_PATH=""

    # shellcheck source=verify_attestation.sh
    source "$SCRIPT"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# A gh stub that records its args and emits a realistic `attestation verify
# --format json` payload. Set GH_STUB_FAIL=1 to simulate a signer mismatch.
install_gh_stub() {
    cat >"$STUB_BIN/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_STUB_ARGS"
if [[ "${GH_STUB_FAIL:-}" == "1" ]]; then
    printf 'verification failed: signer mismatch\n' >&2
    exit 1
fi
cat <<'JSON'
[
  {
    "verificationResult": {
      "statement": {
        "predicate": {
          "buildDefinition": { "buildType": "https://actions.github.io/buildtypes/workflow/v1" },
          "runDetails": { "builder": { "id": "https://github.com/TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml@refs/heads/main" } }
        }
      },
      "signature": {
        "certificate": {
          "subjectAlternativeName": "https://github.com/TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml@refs/heads/main",
          "issuer": "https://token.actions.githubusercontent.com"
        }
      }
    }
  }
]
JSON
EOF
    chmod +x "$STUB_BIN/gh"
    export GH_STUB_ARGS="$TEST_DIR/gh_args"
    : > "$GH_STUB_ARGS"
    PATH="$STUB_BIN:$PATH"
}

@test "verify_attestation: script and validator exist and are executable" {
    [[ -x "$SCRIPT" ]]
    [[ -x "$VALIDATE" ]]
}

# --- input validation ---

@test "verify_attestation: validate accepts good inputs" {
    run "$VALIDATE" "oci://ghcr.io/o/r@sha256:$(printf 'a%.0s' {1..64})" \
        "TomHennen/wrangle" \
        "TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml" \
        "" "https://slsa.dev/provenance/v1" "dist/checksums.txt"
    [[ "$status" -eq 0 ]]
}

@test "verify_attestation: validate rejects subject path traversal" {
    run "$VALIDATE" "../etc/passwd" "TomHennen/wrangle" \
        "TomHennen/wrangle/.github/workflows/x.yml" "" "https://slsa.dev/provenance/v1" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"traversal"* ]]
}

@test "verify_attestation: validate rejects a dash-leading subject (gh flag injection)" {
    run "$VALIDATE" "--predicate-type" "TomHennen/wrangle" \
        "TomHennen/wrangle/.github/workflows/x.yml" "" "https://slsa.dev/provenance/v1" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"must not start with a dash"* ]]
}

@test "verify_attestation: validate rejects a non owner/repo repo" {
    run "$VALIDATE" "dist" "not-a-repo" \
        "TomHennen/wrangle/.github/workflows/x.yml" "" "https://slsa.dev/provenance/v1" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"must be owner/repo"* ]]
}

@test "verify_attestation: validate rejects a signer-workflow without a .yml workflow path" {
    run "$VALIDATE" "dist" "TomHennen/wrangle" "TomHennen/wrangle" "" "https://slsa.dev/provenance/v1" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"signer-workflow"* ]]
}

@test "verify_attestation: validate rejects a non-https predicate-type" {
    run "$VALIDATE" "dist" "TomHennen/wrangle" \
        "TomHennen/wrangle/.github/workflows/x.yml" "" "http://evil/x" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"https:// URL"* ]]
}

@test "verify_attestation: validate rejects a bundle-path with traversal" {
    run "$VALIDATE" "dist" "TomHennen/wrangle" \
        "TomHennen/wrangle/.github/workflows/x.yml" "../../etc/x" "https://slsa.dev/provenance/v1" ""
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"bundle-path"* ]]
}

@test "verify_attestation: validate rejects a checksums-path with traversal" {
    run "$VALIDATE" "dist" "TomHennen/wrangle" \
        "TomHennen/wrangle/.github/workflows/x.yml" "" "https://slsa.dev/provenance/v1" "../../etc/x"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"checksums-path"* ]]
}

# --- gh arg vector ---

@test "verify_attestation: gh args carry repo, signer-workflow, predicate-type" {
    mapfile -t args < <(wrangle_gh_verify_args)
    [[ "${args[0]}" == "attestation" ]]
    [[ "${args[1]}" == "verify" ]]
    printf '%s\n' "${args[@]}" | grep -qx -- "--repo=TomHennen/wrangle"
    printf '%s\n' "${args[@]}" | grep -qx -- "--signer-workflow=TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml"
    printf '%s\n' "${args[@]}" | grep -qx -- "--predicate-type=https://slsa.dev/provenance/v1"
}

@test "verify_attestation: gh args omit --bundle when BUNDLE_PATH is empty" {
    mapfile -t args < <(wrangle_gh_verify_args)
    ! printf '%s\n' "${args[@]}" | grep -q -- "--bundle"
}

@test "verify_attestation: gh args include --bundle when BUNDLE_PATH is set" {
    export BUNDLE_PATH="attestation.jsonl"
    mapfile -t args < <(wrangle_gh_verify_args)
    printf '%s\n' "${args[@]}" | grep -qx -- "--bundle=attestation.jsonl"
}

# --- subject expansion ---

@test "verify_attestation: an oci:// subject expands to itself" {
    export SUBJECT="oci://ghcr.io/o/r@sha256:abc"
    run wrangle_subjects
    [[ "$output" == "oci://ghcr.io/o/r@sha256:abc" ]]
}

@test "verify_attestation: a directory subject fans out to its files" {
    mkdir -p "$TEST_DIR/dist"
    touch "$TEST_DIR/dist/a.tgz" "$TEST_DIR/dist/b.tgz"
    export SUBJECT="$TEST_DIR/dist"
    run wrangle_subjects
    [[ "${lines[0]}" == "$TEST_DIR/dist/a.tgz" ]]
    [[ "${lines[1]}" == "$TEST_DIR/dist/b.tgz" ]]
    [[ "${#lines[@]}" -eq 2 ]]
}

@test "verify_attestation: CHECKSUMS_PATH selects only checksums-listed files, not the whole dir" {
    mkdir -p "$TEST_DIR/dist"
    # A real goreleaser dist: two release archives plus bookkeeping that must
    # NOT be verified. Only the archives are in checksums.txt.
    touch "$TEST_DIR/dist/app_linux.tar.gz" "$TEST_DIR/dist/app_darwin.tar.gz" \
        "$TEST_DIR/dist/artifacts.json" "$TEST_DIR/dist/metadata.json"
    printf 'aaa  app_linux.tar.gz\nbbb  app_darwin.tar.gz\n' > "$TEST_DIR/dist/checksums.txt"
    export SUBJECT="$TEST_DIR/dist"
    export CHECKSUMS_PATH="$TEST_DIR/dist/checksums.txt"
    run wrangle_subjects
    [[ "${#lines[@]}" -eq 2 ]]
    [[ "$output" == *"$TEST_DIR/dist/app_linux.tar.gz"* ]]
    [[ "$output" == *"$TEST_DIR/dist/app_darwin.tar.gz"* ]]
    [[ "$output" != *"artifacts.json"* ]]
    [[ "$output" != *"metadata.json"* ]]
}

@test "verify_attestation: CHECKSUMS_PATH preserves filenames with internal whitespace" {
    printf 'aaa  my app.tar.gz\n' > "$TEST_DIR/checksums.txt"
    export SUBJECT="dist"
    export CHECKSUMS_PATH="$TEST_DIR/checksums.txt"
    run wrangle_subjects
    [[ "$output" == "dist/my app.tar.gz" ]]
}

# --- end-to-end verify (gh stub) ---

@test "verify_attestation: verifies each file in a directory and prints identities" {
    install_gh_stub
    mkdir -p "$TEST_DIR/dist"
    touch "$TEST_DIR/dist/a.tgz" "$TEST_DIR/dist/b.tgz"
    export SUBJECT="$TEST_DIR/dist"
    run wrangle_verify_attestation
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"builder.id:  https://github.com/TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml"* ]]
    [[ "$output" == *"buildType:   https://actions.github.io/buildtypes/workflow/v1"* ]]
    [[ "$output" == *"signer SAN:  https://github.com/TomHennen/wrangle"* ]]
    # one gh invocation per file
    [[ "$(wc -l < "$GH_STUB_ARGS")" -eq 2 ]]
}

@test "verify_attestation: passes --bundle and subject through to gh" {
    install_gh_stub
    export SUBJECT="oci://ghcr.io/o/r@sha256:abc"
    export BUNDLE_PATH="$TEST_DIR/bundle.jsonl"
    run wrangle_verify_attestation
    [[ "$status" -eq 0 ]]
    run cat "$GH_STUB_ARGS"
    [[ "$output" == *"--bundle=$TEST_DIR/bundle.jsonl"* ]]
    [[ "$output" == *"oci://ghcr.io/o/r@sha256:abc"* ]]
    [[ "$output" == *"--signer-workflow=TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml"* ]]
}

@test "verify_attestation: fails closed when gh verification fails" {
    install_gh_stub
    export GH_STUB_FAIL="1"
    export SUBJECT="oci://ghcr.io/o/r@sha256:abc"
    run wrangle_verify_attestation
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"FAILED"* ]]
}

@test "verify_attestation: fails closed when a directory has no files (no vacuous pass)" {
    install_gh_stub
    mkdir -p "$TEST_DIR/empty"
    export SUBJECT="$TEST_DIR/empty"
    run wrangle_verify_attestation
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no subjects to verify"* ]]
}
