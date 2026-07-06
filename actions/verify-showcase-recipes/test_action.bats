#!/usr/bin/env bats

# Structure guard for the verify-showcase-recipes composite and hermetic tests
# for run_recipes.sh's env->flag assembly (stub runner, no tools, no network).

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$DIR/action.yml"
    RUN="$DIR/run_recipes.sh"
    STUB="$BATS_TEST_TMPDIR/runner.sh"
    # A stub runner that records the exact argv it was called with.
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$STUB"
    chmod +x "$STUB"
    export DIR ACTION RUN STUB
}

@test "action is a composite that installs tools then runs the recipes" {
    grep -Fq "using: composite" "$ACTION"
    grep -Fq '${{ github.action_path }}/install_tools.sh' "$ACTION"
    grep -Fq '${{ github.action_path }}/run_recipes.sh' "$ACTION"
}

@test "action threads every coordinate through env, not the run body" {
    # Attacker-controllable inputs must reach the script via env: (WWL002), so the
    # run: bodies are bare script paths with no ${{ inputs.* }} interpolation.
    grep -Fq 'FILE: ${{ inputs.file }}' "$ACTION"
    grep -Fq 'REPO: ${{ inputs.repo }}' "$ACTION"
    grep -Fq 'GITHUB_TOKEN: ${{ inputs.github-token }}' "$ACTION"
    run bash -c 'grep -E "run: .*\\$\\{\\{ inputs\\." "$ACTION"'
    [[ "$status" -ne 0 ]]
}

@test "install_tools.sh installs ampel + cosign from tools/go.mod (single source)" {
    grep -Fq 'go -C "$REPO_ROOT/tools" install' "$DIR/install_tools.sh"
    grep -Fq 'github.com/carabiner-dev/ampel/cmd/ampel' "$DIR/install_tools.sh"
    grep -Fq 'github.com/sigstore/cosign/v3/cmd/cosign' "$DIR/install_tools.sh"
}

@test "run_recipes.sh assembles file-class flags from env" {
    WRANGLE_RECIPE_RUNNER="$STUB" \
        FILE=dist/pkg.tgz BUNDLE=dist/pkg.tgz.intoto.jsonl \
        RESOURCE_URI="pkg:npm/x@1" REPO=o/r BUILD_TYPE=npm \
        run "$RUN"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--file"$'\n'"dist/pkg.tgz"* ]]
    [[ "$output" == *"--bundle"$'\n'"dist/pkg.tgz.intoto.jsonl"* ]]
    [[ "$output" == *"--type"$'\n'"npm"* ]]
}

@test "run_recipes.sh emits boolean flags only when true" {
    WRANGLE_RECIPE_RUNNER="$STUB" \
        IMAGE=ghcr.io/o/i DIGEST=abc REPO=o/r \
        PROVENANCE=false ATTESTATION_STORE=true NON_STRICT=false \
        run "$RUN"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--attestation-store"* ]]
    [[ "$output" != *"--provenance"* ]]
    [[ "$output" != *"--non-strict"* ]]
}

@test "run_recipes.sh omits flags for empty inputs" {
    WRANGLE_RECIPE_RUNNER="$STUB" REPO=o/r run "$RUN"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"--file"* ]]
    [[ "$output" != *"--image"* ]]
    [[ "$output" == *"--repo"$'\n'"o/r"* ]]
}
