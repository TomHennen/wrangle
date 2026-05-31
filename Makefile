.PHONY: all test lint shellcheck shellstyle workflowstyle bats zizmor bump-action-pins

# Default target
all: test

# Run all local checks
test: lint shellcheck shellstyle workflowstyle bats zizmor

# Validate all workflow and action YAML files
lint:
	@echo "=== actionlint ==="
	@actionlint

# Run wrangle-specific shell style linter (CLAUDE.md rules not covered by shellcheck)
shellstyle:
	@echo "=== wrangle-shell-lint ==="
	@./tools/wrangle-shell-lint/lint.sh

# Run wrangle-specific workflow style linter (CLAUDE.md GitHub Actions rules:
# run-block length, expression injection, continue-on-error justification)
workflowstyle:
	@echo "=== wrangle-workflow-lint ==="
	@./tools/wrangle-workflow-lint/lint.sh

# Lint all shell scripts
shellcheck:
	@echo "=== shellcheck ==="
	@SCRIPTS=$$(find . -name '*.sh' -not -path './.git/*' -not -path './.beads/*' -not -path './.claude/*'); \
	if [ -n "$$SCRIPTS" ]; then \
		echo $$SCRIPTS | xargs shellcheck -x --source-path=SCRIPTDIR; \
	else \
		echo "No shell scripts to check"; \
	fi

# Run bats tests
bats:
	@echo "=== bats ==="
	@bats test/ test/lib/ test/integration/ tools/*/test.bats actions/*/*.bats build/actions/*/test.bats

# Workflow security linting (matches tools/zizmor/action.yml's CI invocation).
# --no-online-audits keeps the test container offline-friendly; the
# online audits (e.g. unpinned-uses against the live registry) are
# exercised by the same upstream action in CI.
zizmor:
	@echo "=== zizmor ==="
	@zizmor --no-online-audits .github/workflows actions/ tools/ build/

# Bump every TomHennen/wrangle/...@<sha> ref in .github/workflows/ to current HEAD.
# Idempotent. See tools/bump_action_pins.sh and #165.
# Usage: make bump-action-pins             # bump to HEAD
#        make bump-action-pins SHA=<sha>   # bump to a specific SHA
bump-action-pins:
	@./tools/bump_action_pins.sh $(SHA)

# Update a tool version and its checksum
# Usage: make update-tool TOOL=osv VERSION=1.2.3
update-tool:
	@echo "Tool version update helper — not yet implemented"
	@echo "Will download $(TOOL) $(VERSION), compute SHA-256, and patch tools/$(TOOL)/install.sh"
	@exit 1
