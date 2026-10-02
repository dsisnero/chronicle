# Pull Request Workflow

1. Create a focused branch and make the smallest complete change.
2. Run `make format-check`, `make lint`, and `make test` locally.
3. Add red-green specs for behavior changes; port upstream tests where they
   exist and don't weaken them to fit the Crystal port.
4. Update the affected rows in `plans/parity.md` (and the inventory TSV) when
   the change ports or defers activegraph surface.
5. Update the user-facing docs under `docs/` (concepts, guides, cookbook,
   reference, API) and this repo's `README.md` links when behavior changes.
6. Describe behavior changes and any intentional divergence from activegraph
   in the pull request.
7. Keep generated files and local scratch artifacts out of commits.
