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

# Run act-based action tests (requires act + Docker on the host)
test-actions:
	@echo "=== act-based action tests ==="
	@echo "--- test: shell action ---"
	@act push -W test/act/test-shell-action.yml -e test/act/event.json \
		-P ubuntu-latest=catthehacker/ubuntu:act-latest --bind
	@echo "--- test: scan orchestrator ---"
	@act push -W test/act/test-scan-orchestrator.yml -e test/act/event.json \
		-P ubuntu-latest=catthehacker/ubuntu:act-latest --bind

# Update a tool version and its checksum
# Usage: make update-tool TOOL=osv VERSION=1.2.3
update-tool:
	@echo "Tool version update helper — not yet implemented"
	@echo "Will download $(TOOL) $(VERSION), compute SHA-256, and patch tools/$(TOOL)/install.sh"
	@exit 1
