.PHONY: all test lint shellcheck bats test-actions

# Default target
all: test

# Run all local checks
test: lint shellcheck bats

# Validate all workflow and action YAML files
lint:
	@echo "=== actionlint ==="
	@actionlint

# Lint all shell scripts
shellcheck:
	@echo "=== shellcheck ==="
	@SCRIPTS=$$(find . -name '*.sh' -not -path './.git/*' -not -path './.beads/*'); \
	if [ -n "$$SCRIPTS" ]; then \
		echo $$SCRIPTS | xargs shellcheck -x --source-path=SCRIPTDIR; \
	else \
		echo "No shell scripts to check"; \
	fi

# Run bats tests
bats:
	@echo "=== bats ==="
	@bats test/ test/lib/ tools/*/test.bats

# Run act-based action tests (requires act + Docker on the host).
# Discovers test workflows by globbing **/test/test_workflow.yml under
# build/actions/ and actions/. Adding a new action with a test_workflow.yml
# automatically picks it up.
test-actions:
	@echo "=== act-based action tests ==="
	@WORKFLOWS=$$(find build/actions actions -path '*/test/test_workflow.yml' 2>/dev/null); \
	if [ -z "$$WORKFLOWS" ]; then \
		echo "No act test workflows found"; exit 1; \
	fi; \
	for wf in $$WORKFLOWS; do \
		echo "--- test: $$wf ---"; \
		act push -W "$$wf" -e test/act/event.json \
			-P ubuntu-latest=catthehacker/ubuntu:act-latest || exit $$?; \
	done

# Update a tool version and its checksum
# Usage: make update-tool TOOL=osv VERSION=1.2.3
update-tool:
	@echo "Tool version update helper — not yet implemented"
	@echo "Will download $(TOOL) $(VERSION), compute SHA-256, and patch tools/$(TOOL)/install.sh"
	@exit 1
