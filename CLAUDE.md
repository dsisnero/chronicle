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

## Sans-IO HTTP/1 Guidance

Before changing HTTP/1 framing or connection-state semantics, consult
[h11's DeepWiki](https://deepwiki.com/python-hyper/h11) and the upstream
[`python-hyper/h11`](https://github.com/python-hyper/h11) source/tests. Treat
DeepWiki as guidance and h11's pinned source plus the HTTP RFCs as the
conformance reference. Add focused, MIT-attributed normalized fixtures under
`spec/`; do not vendor h11 as a submodule or import GPL fuzz projects into this
repository.

## Log-Primary Agent Design (The Log is the Agent)

Before changing fork, replay, or log-projection semantics, consult
[activegraph DeepWiki](https://deepwiki.com/yoheinakajima/activegraph) for
context on the event-sourced, reactive-graph design from the paper
[The Log is the Agent](https://arxiv.org/html/2605.21997v1). DeepWiki is
guidance, not the source of truth; validate against the paper and the pinned
repo source.
