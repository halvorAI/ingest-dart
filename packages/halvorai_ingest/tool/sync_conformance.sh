#!/bin/sh
# Refreshes test/fixtures/conformance/ from the published ape-schema conformance files, the
# same ones the Node.js and Python SDKs test against. Run from the package directory, then
# run `dart test`.
set -eu

base="${APE_SCHEMA_URL:-https://schema.halvorai.com}/conformance"
dir="test/fixtures/conformance"
mkdir -p "$dir"
for file in events.json sign-vector.json jcs-vectors.json; do
  curl -fsS -o "$dir/$file" "$base/$file"
  echo "updated $dir/$file"
done
