# Development

Use Crystal 1.21 or newer, as declared in `shard.yml`.

```bash
make format-check
make lint
make test
```

Use `make format` to apply the standard Crystal formatter. Keep temporary
artifacts under `temp/`; `make clean` clears that directory's contents.
