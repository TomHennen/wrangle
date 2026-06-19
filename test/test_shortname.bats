#!/usr/bin/env bats

# Tests for lib/shortname.sh — the single path-derived shortname/artifact-name
# logic shared by all build types, so they can't drift on the root-path case.

setup() {
    ORIG_DIR="$(pwd)"
    export ORIG_DIR
    source "$ORIG_DIR/lib/shortname.sh"
}

@test "shortname: root '.' derives to empty" {
    [[ "$(derive_shortname ".")" == "" ]]
}

@test "shortname: a subdir maps '/' to '_'" {
    [[ "$(derive_shortname "services/api")" == "services_api" ]]
    [[ "$(derive_shortname "a/b/c")" == "a_b_c" ]]
}

@test "shortname: a trailing slash is stripped" {
    [[ "$(derive_shortname "foo/")" == "foo" ]]
    [[ "$(derive_shortname "a/b/")" == "a_b" ]]
}

@test "shortname: a leading slash is stripped" {
    [[ "$(derive_shortname "/foo")" == "foo" ]]
    [[ "$(derive_shortname "/a/b")" == "a_b" ]]
}

@test "shortname: repeated slashes collapse" {
    [[ "$(derive_shortname "a//b")" == "a_b" ]]
    [[ "$(derive_shortname "/a//b/")" == "a_b" ]]
}

@test "shortname: artifact_name omits the suffix when the shortname is empty" {
    [[ "$(artifact_name go-metadata "")" == "go-metadata" ]]
    [[ "$(artifact_name container-scan "")" == "container-scan" ]]
}

@test "shortname: artifact_name appends '-<shortname>' for a subdir" {
    [[ "$(artifact_name go-metadata "services_api")" == "go-metadata-services_api" ]]
}

@test "shortname: metadata_dir is clean (no trailing slash) at the root" {
    [[ "$(metadata_dir go "")" == "metadata/go" ]]
    [[ "$(metadata_dir container "")" == "metadata/container" ]]
}

@test "shortname: metadata_dir nests under the shortname for a subdir" {
    [[ "$(metadata_dir python "pkg_foo")" == "metadata/python/pkg_foo" ]]
}
