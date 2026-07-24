# Clarity

Clarity is a Crystal library scaffold.

## Commands

```bash
# Format source and specs
crystal tool format src spec

# Check formatting without changing files
crystal tool format --check src spec

# Run static analysis
ameba src spec

# Run the test suite (uses the repo-local ignored Crystal cache)
make test

# Remove generated local artifacts
make clean
```

## Documentation

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [Coding guidelines](docs/coding-guidelines.md)
- [Testing](docs/testing.md)
- [Pull request workflow](docs/pr-workflow.md)

## Principles

- Keep the public API small and documented.
- Keep generated or scratch artifacts in `temp/`.
- Make formatting, static analysis, and tests pass before submitting changes.

## Conventions

- Production code belongs in `src/`; tests belong in `spec/`.
- Define the library version as `Clarity::VERSION`.

## Deterministic Routing Guidance

Before changing deterministic-routing semantics, consult the
[Smista DeepWiki](https://deepwiki.com/smista-ai/smista.ai) for repository
context, then validate the recommendation against Smista's source and
configuration documentation. Record the adopted precedence, tie-break, privacy,
or fallback rule in `plans/implementation.md` and cover it with a deterministic
test; DeepWiki is guidance, not the source of truth.
