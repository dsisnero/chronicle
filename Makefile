.PHONY: format format-check lint test test-interactive test-falkordb http-fixtures clean

FALKORDB_CONTAINER ?= chronicle-falkordb-test
FALKORDB_NETWORK ?= chronicle-falkordb-test-network
FALKORDB_IMAGE ?= falkordb/falkordb:latest
FALKORDB_TEST_IMAGE ?= crystallang/crystal:1.21.0
FALKORDB_SERVER_MEMORY ?= 2G
FALKORDB_TEST_MEMORY ?= 4G
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

# macOS live integration gate. Requires Apple's `container` CLI; it owns an
# isolated server/client network and always removes the authenticated instance.
test-falkordb:
	@set -eu; \
	name='$(FALKORDB_CONTAINER)'; \
	network='$(FALKORDB_NETWORK)'; \
	cleanup() { container delete -f "$$name" >/dev/null 2>&1 || true; container network delete "$$network" >/dev/null 2>&1 || true; }; \
	trap cleanup EXIT INT TERM; \
	cleanup; \
	container network create "$$network" >/dev/null; \
	container run --rm -d --memory '$(FALKORDB_SERVER_MEMORY)' --name "$$name" --network "$$network" --env 'BROWSER=0' --env 'REDIS_ARGS=--requirepass $(FALKORDB_PASSWORD)' '$(FALKORDB_IMAGE)' >/dev/null; \
	ready=0; \
	for attempt in $$(seq 1 30); do \
		if container exec "$$name" redis-cli --no-auth-warning -a '$(FALKORDB_PASSWORD)' ping 2>/dev/null | grep -qx PONG; then ready=1; break; fi; \
		sleep 1; \
	done; \
	test "$$ready" -eq 1 || { container logs "$$name"; echo "FalkorDB did not become ready" >&2; exit 1; }; \
	server_ip=$$(container inspect "$$name" | ruby -rjson -e 'puts JSON.parse(STDIN.read)[0].dig("status", "networks", 0, "ipv4Address").split("/").first'); \
	container run --rm --memory '$(FALKORDB_TEST_MEMORY)' --network "$$network" --mount 'type=bind,source=$(CURDIR),target=/workspace,readonly' --workdir /workspace --env "FALKORDB_URL=falkor://$$server_ip:6379" --env 'FALKORDB_PASSWORD=$(FALKORDB_PASSWORD)' --env 'CRYSTAL_CACHE_DIR=/tmp/chronicle-crystal-cache' '$(FALKORDB_TEST_IMAGE)' sh -ec 'apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libsqlite3-dev; crystal spec spec/chronicle/falkordb_graph_store_spec.cr'

http-fixtures:
	sh ./scripts/check_h11_fixture_provenance.sh

example:
	crystal examples/deepseek_routing.cr

chat:
	crystal run src/chronicle/cli_main.cr -- chat

clean:
	find temp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
