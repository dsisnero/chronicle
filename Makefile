.PHONY: format format-check lint test clean

format:
	crystal tool format src spec

format-check:
	crystal tool format --check src spec

lint:
	ameba src spec

test:
	CRYSTAL_CACHE_DIR=$(CURDIR)/.crystal-cache crystal spec

clean:
	find temp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
