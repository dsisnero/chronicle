#!/bin/sh
set -eu

readonly H11_COMMIT="62c5068c971579d61fa1b55373390e12f25fd856"
readonly FIXTURE_SPEC="spec/clarity/sans_io_http_spec.cr"

if ! rg -Fq "python-hyper/h11@${H11_COMMIT}" "$FIXTURE_SPEC"; then
  echo "missing pinned h11 fixture provenance: ${H11_COMMIT}" >&2
  exit 1
fi

if ! rg -Fq "(MIT; https://github.com/python-hyper/h11)" "$FIXTURE_SPEC"; then
  echo "missing h11 MIT attribution" >&2
  exit 1
fi

echo "h11 fixture provenance is pinned to ${H11_COMMIT}"
