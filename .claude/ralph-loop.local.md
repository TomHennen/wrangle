---
active: true
iteration: 1
session_id: 
max_iterations: 30
completion_promise: "DONE"
started_at: "2026-04-12T18:37:19Z"
---


  ## Task: Implement local action testing via act (issue #115)

  Add nektos/act to wrangle's test infrastructure so composite actions can be tested locally before pushing to CI. This supplements (not replaces) the existing bats + shellcheck + actionlint test suite.

  ## Context you need

  - Wrangle is a supply chain security tool for GitHub Actions. Read CLAUDE.md for all coding rules.
  - test.sh builds a Docker image from test/Dockerfile (Ubuntu 24.04) and runs make test inside it.
  - Makefile has targets: test (lint + shellcheck + bats), bats, lint, shellcheck.
  - CI (.github/workflows/test.yml) just runs ./test.sh.
  - Existing bats tests are in test/, test/lib/, and tools/*/test.bats.
  - Mock pattern: create mock executables in temp dirs, prepend to PATH, control behavior via env vars.

  ## Act limitations (already researched — do NOT try to work around these)

  These DO NOT WORK in act and you must NOT attempt to test them via act:
  - actions/upload-artifact (auth errors with v7)
  - github/codeql-action/upload-sarif (needs real GitHub API)
  - docker/build-push-action and docker/setup-buildx-action (Docker-in-Docker broken)
  - ossf/scorecard-action (needs Docker + elevated token scopes)
  - Composite action step output propagation to calling workflows (act bug #2184)

  These DO WORK in act:
  - Local composite action resolution (uses: ./path/to/action)
  - Shell run: steps inside composite actions
  - env: propagation within a composite action
  - GITHUB_OUTPUT (within a single composite action, not across)
  - GITHUB_STEP_SUMMARY (file created, content written)
  - github.action_path for local actions
  - github.workspace, github.event_name and most github.* context

  ## Phases — complete them in order

  ### Phase 1: Add act to test container and Makefile

  Files to modify:
  - test/Dockerfile — install act binary (download from GitHub releases, verify checksum, same pattern as actionlint install in the Dockerfile). Use the latest stable release. Support both amd64 and arm64.
  - Makefile — add make test-actions target that runs act. For now it can just verify act is installed (act --version).

  Success criteria:
  - ./test.sh test-actions passes (act binary runs inside the container)
  - Existing make test still passes (no regressions)
  - act binary is checksum-verified in the Dockerfile (match the pattern used for actionlint)
  - Shell in Dockerfile follows CLAUDE.md rules (but note: Dockerfile RUN commands don't need set -euo pipefail since Docker handles that via shell form)

  ### Phase 2: Test build/actions/shell via act

  This is the easiest composite action — pure bash, no Docker, no GitHub API.

  Files to create:
  - test/act/test-shell-action.yml — a minimal GitHub Actions workflow that exercises build/actions/shell/action.yml against wrangle itself (or a small fixture project under test/act/fixtures/). The workflow should run shellcheck + bats and verify they pass.
  - test/act/event.json — a minimal push event payload for act.

  Files to modify:
  - Makefile — update test-actions target to run: act -W test/act/test-shell-action.yml -e test/act/event.json --container-architecture linux/amd64

  Success criteria:
  - make test-actions runs the shell action via act inside the test container and it passes
  - The test exercises real behavior: shellcheck runs on .sh files, bats discovers and runs tests
  - No network calls to GitHub API (act runs fully offline except for action resolution)

  ### Phase 3: Smoke-test actions/scan orchestrator via act

  This is harder because actions/scan uses upload-sarif and upload-artifact which fail in act. The approach: create a test workflow that exercises ONLY the orchestrator and adapter logic (the shell run: steps), not the upload steps.

  Files to create:
  - test/act/test-scan-orchestrator.yml — a workflow that:
    1. Sets up wrangle env vars (WRANGLE_METADATA_DIR, WRANGLE_TOOLS_DIR, etc.)
    2. Runs the orchestrator (run.sh) directly against wrangle's own source with a single tool (osv)
    3. Verifies output files exist (SARIF at expected paths, metadata directory structure)
    4. Does NOT attempt SARIF upload or artifact upload
    NOTE: This tests the orchestrator end-to-end in a GitHub Actions-like environment, complementing the existing bats unit tests which use mock tools.

  Files to create:
  - test/act/fixtures/shell-project/ — a tiny shell project with one .sh file and one test.bats, used as a test target for the shell action test if testing against wrangle itself is too slow.

  Success criteria:
  - make test-actions runs both test workflows (shell action + scan orchestrator)
  - The scan orchestrator produces SARIF output at the expected path
  - The metadata directory structure matches what CI would produce
  - No attempts to call GitHub API (no upload-sarif, no upload-artifact)

  ### Phase 4: Structural bats tests for what act can't cover

  Add bats tests that validate the WIRING of things act can't execute, without actually running them.

  Files to create:
  - test/test_action_structure.bats — structural tests for all composite actions:
    - Every action.yml under actions/ and tools/ is valid YAML (parse with yq or python)
    - All uses: references are SHA-pinned (no @main, no bare @v*)
    - actions/scan/action.yml has upload-sarif steps with correct categories (wrangle/osv, wrangle/scorecard)
    - actions/scan/action.yml has upload-artifact step
    - build/actions/container/action.yml has input validation step with set -f
    - tools/scorecard/action.yml and tools/zizmor/action.yml exist and wrap upstream actions

  Success criteria:
  - make test (which includes bats) runs the new structural tests and they pass
  - The structural tests catch real issues: if someone removes a SARIF upload step or changes a category, the test fails
  - Tests follow existing bats patterns (setup/teardown, temp dirs, status checks)

  ### Phase 5: Wire into CI and document

  Files to modify:
  - Makefile — make test-actions is the final form (runs all act-based test workflows)
  - test.sh — add test-actions as a supported target alongside test, bats, lint, shellcheck. Update the default 'all' target to include test-actions.
  - .github/workflows/test.yml — no changes needed (it already runs ./test.sh which runs make all)

  Files to create or update:
  - NONE — do not create README files or documentation unless asked.

  Success criteria:
  - ./test.sh runs all tests including act-based tests
  - ./test.sh test-actions runs only the act-based tests
  - Existing ./test.sh (no args) still passes with act tests included
  - No CI changes needed (test.yml already delegates to test.sh)

  ## Rules

  - Read CLAUDE.md before writing any code. Follow ALL shell script safety rules.
  - Every shell script must start with set -euo pipefail. Every variable must be double-quoted.
  - All shell scripts must pass shellcheck. No # shellcheck disable without justification.
  - Use printf not echo for output that may contain variable data.
  - Do NOT create documentation files (README.md, etc.) unless explicitly asked.
  - Do NOT modify any existing test files — only create new ones and modify Makefile/test.sh/Dockerfile.
  - Run ./test.sh after each phase to verify no regressions. If tests fail, fix before moving on.
  - Commit after each phase with a descriptive message.
  - If act has a problem you didn't expect (e.g., a composite action feature doesn't work), add a structural bats test for that case instead of trying to force act to work. Do not spend more than 2 iterations on any single act compatibility issue.

  ## Completion

  When ALL of the following are true, output <promise>DONE</promise>:
  1. ./test.sh passes (all existing tests + new tests)
  2. ./test.sh test-actions passes (act-based tests run successfully)
  3. make test-actions works inside the Docker container
  4. At least 2 composite actions are exercised via act (shell action + scan orchestrator)
  5. Structural bats tests exist for action wiring that act can't cover
  6. All new shell code passes shellcheck
  7. All phases have been committed
  
