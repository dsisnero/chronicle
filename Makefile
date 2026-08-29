.PHONY: format format-check lint test test-interactive test-falkordb http-fixtures clean

FALKORDB_CONTAINER ?= chronicle-falkordb-test
FALKORDB_IMAGE ?= falkordb/falkordb:latest
FALKORDB_PORT ?= 6380
FALKORDB_PASSWORD ?= chronicle-parity-password

format:
	crystal tool format src spec

format-check:
	crystal tool format --check src spec

lint:
	ameba src spec

test:
	CRYSTAL_CACHE_DIR=$(CURDIR)/.crystal-cache crystal spec -- --tag '~interactive'

test-interactive:
	CRYSTAL_CACHE_DIR=$(CURDIR)/.crystal-cache crystal spec -- --tag interactive

# macOS live integration gate. Requires Apple's `container` CLI; it owns the
# disposable server lifecycle and always removes the authenticated instance.
test-falkordb:
	@set -eu; \
	name='$(FALKORDB_CONTAINER)'; \
	password='$(FALKORDB_PASSWORD)'; \
	cleanup() { container delete -f "$$name" >/dev/null 2>&1 || true; }; \
	trap cleanup EXIT INT TERM; \
	cleanup; \
	container run --rm -d --name "$$name" --publish '$(FALKORDB_PORT):6379' --env 'BROWSER=0' --env 'REDIS_ARGS=--requirepass $(FALKORDB_PASSWORD)' '$(FALKORDB_IMAGE)' >/dev/null; \
	ready=0; \
	for attempt in $$(seq 1 30); do \
		if container exec "$$name" redis-cli --no-auth-warning -a '$(FALKORDB_PASSWORD)' ping 2>/dev/null | grep -qx PONG; then ready=1; break; fi; \
		sleep 1; \
	done; \
	test "$$ready" -eq 1 || { container logs "$$name"; echo "FalkorDB did not become ready" >&2; exit 1; }; \
	printf '*2\r\n$$4\r\nAUTH\r\n$$%s\r\n%s\r\n*1\r\n$$4\r\nPING\r\n' "$${#password}" "$$password" | nc -w 3 127.0.0.1 '$(FALKORDB_PORT)' | tr -d '\r' | grep -qx '+PONG' || { echo "Apple Container did not expose FalkorDB on 127.0.0.1:$(FALKORDB_PORT)" >&2; exit 1; }; \
	FALKORDB_URL='falkor://127.0.0.1:$(FALKORDB_PORT)' FALKORDB_PASSWORD='$(FALKORDB_PASSWORD)' CRYSTAL_CACHE_DIR='$(CURDIR)/.crystal-cache' crystal spec spec/chronicle/falkordb_graph_store_spec.cr

http-fixtures:
	sh ./scripts/check_h11_fixture_provenance.sh

example:
	crystal examples/deepseek_routing.cr

chat:
	crystal run src/chronicle/cli_main.cr -- chat

clean:
	find temp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
