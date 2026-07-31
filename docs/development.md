# Development

Use Crystal 1.21 or newer, as declared in `shard.yml`.

## Commands

```bash
make format           # apply the standard Crystal formatter
make format-check     # verify formatting without changing files
make lint             # run ameba static analysis
make test             # run the spec suite (repo-local Crystal cache)
make clean            # clear temp/ scratch artifacts
```

`make test` runs `crystal spec` with a repo-local `CRYSTAL_CACHE_DIR` so the
external SSD's default cache is not relied on.

## Workflow

- Work phase-by-phase from `plans/parity.md`; the plan tracks ported vs
  deferred activegraph surface with checkboxes.
- Follow red-green TDD: write the failing spec, make the smallest change that
  turns it green, run focused checks, then the full gates.
- Before submitting, run `make format-check`, `make lint`, and `make test`.

## Notes

- The suite is deterministic and offline — no live provider calls; model and
  tool behavior is driven by recorded fixtures and mocks.
- Keep temporary artifacts under `temp/`; `make clean` removes them.
- `vendor/activegraph/` is the pinned upstream source of truth (see
  `plans/parity.md`); do not edit it — validate ported behavior against it.
