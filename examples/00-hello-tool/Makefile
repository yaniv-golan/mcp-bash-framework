# Makefile for hello-tool-example MCP server

.PHONY: help validate bundle clean test

help:
	@echo "Available targets:"
	@echo "  make validate  - Validate project structure"
	@echo "  make bundle    - Create MCPB bundle for distribution"
	@echo "  make clean     - Remove generated files"
	@echo "  make test      - Run tool tests"

validate:
	mcp-bash validate

bundle:
	mcp-bash bundle --verbose

clean:
	rm -f *.mcpb
	rm -rf .registry/

test:
	@if [ -f test/run.sh ]; then \
		./test/run.sh; \
	else \
		echo "No test harness found. Run 'mcp-bash scaffold test' to create one."; \
	fi
