#!/usr/bin/env bats

# Tests for lib/derive_names.sh — the shared artifact-name derivation the
# four reusable build workflows call so the names can't drift between build
# types.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/lib/derive_names.sh"
    GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
    export GITHUB_OUTPUT
    : > "$GITHUB_OUTPUT"
}

@test "package_metadata: root build emits suffix-less names" {
    run "$SCRIPT" go ""
    [ "$status" -eq 0 ]
    grep -qx 'dist=go-dist' "$GITHUB_OUTPUT"
    grep -qx 'scan=go-scan' "$GITHUB_OUTPUT"
    grep -qx 'checks=go-checks' "$GITHUB_OUTPUT"
    grep -qx 'metadata=go-metadata' "$GITHUB_OUTPUT"
    grep -qx 'metadata-pre=go-premeta' "$GITHUB_OUTPUT"
    grep -qx 'provenance-bundle=go-provenance-bundle' "$GITHUB_OUTPUT"
    grep -qx 'signed-metadata=go-signed-metadata' "$GITHUB_OUTPUT"
}

@test "package_metadata: subdir build appends the shortname" {
    run "$SCRIPT" python services_api
    [ "$status" -eq 0 ]
    grep -qx 'dist=python-dist-services_api' "$GITHUB_OUTPUT"
    grep -qx 'metadata=python-metadata-services_api' "$GITHUB_OUTPUT"
    grep -qx 'metadata-pre=python-premeta-services_api' "$GITHUB_OUTPUT"
    grep -qx 'provenance-bundle=python-provenance-bundle-services_api' "$GITHUB_OUTPUT"
    grep -qx 'signed-metadata=python-signed-metadata-services_api' "$GITHUB_OUTPUT"
}

@test "package_metadata: each build type namespaces its names" {
    run "$SCRIPT" container ""
    [ "$status" -eq 0 ]
    grep -qx 'metadata=container-metadata' "$GITHUB_OUTPUT"

    : > "$GITHUB_OUTPUT"
    run "$SCRIPT" npm ""
    [ "$status" -eq 0 ]
    grep -qx 'metadata=npm-metadata' "$GITHUB_OUTPUT"
}

@test "package_metadata: accepts a hyphen/dot shortname (path 'python-uv', 'a.b_c')" {
    run "$SCRIPT" python python-uv
    [ "$status" -eq 0 ]
    grep -qx 'metadata=python-metadata-python-uv' "$GITHUB_OUTPUT"

    : > "$GITHUB_OUTPUT"
    run "$SCRIPT" go a.b_c
    [ "$status" -eq 0 ]
    grep -qx 'metadata=go-metadata-a.b_c' "$GITHUB_OUTPUT"
}

@test "package_metadata: derives the shortname from a path (scan-job mode)" {
    run "$SCRIPT" python "" services/api
    [ "$status" -eq 0 ]
    grep -qx 'scan=python-scan-services_api' "$GITHUB_OUTPUT"
    grep -qx 'shortname=services_api' "$GITHUB_OUTPUT"
}

@test "package_metadata: root path derives an empty shortname" {
    run "$SCRIPT" go "" .
    [ "$status" -eq 0 ]
    grep -qx 'scan=go-scan' "$GITHUB_OUTPUT"
    grep -qx 'shortname=' "$GITHUB_OUTPUT"
}

@test "package_metadata: explicit shortname wins over path" {
    run "$SCRIPT" npm given ignored/path
    [ "$status" -eq 0 ]
    grep -qx 'scan=npm-scan-given' "$GITHUB_OUTPUT"
}

@test "package_metadata: rejects a shortname with a path separator" {
    run "$SCRIPT" go "a/b"
    [ "$status" -ne 0 ]
}

@test "package_metadata: rejects a shortname with a shell metachar" {
    run "$SCRIPT" go 'x;rm'
    [ "$status" -ne 0 ]
}

@test "package_metadata: rejects an invalid build type" {
    run "$SCRIPT" 'go;rm' ""
    [ "$status" -ne 0 ]
}

@test "package_metadata: requires two args" {
    run "$SCRIPT" go
    [ "$status" -ne 0 ]
}
