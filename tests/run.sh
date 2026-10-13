#!/usr/bin/env bash
# Decimal parity vs shopspring/decimal (needs Go with the module cache) — 3 x 20k random ops.
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO:-mojo}
mkdir -p build
$MOJO build --fp-mode contract=off -O3 -I src tests/dec/main.mojo -o build/decfuzz -Xlinker -lssl -Xlinker -lcrypto
(cd tests/dec && GOFLAGS=-mod=mod go build -o ../../build/decfuzz_go .)
for s in 1 2 3; do python3 tests/dec/gen.py $s 20000 > build/dec.txt; cmp <(build/decfuzz_go < build/dec.txt) <(build/decfuzz < build/dec.txt) && echo "PASS decimal seed $s"; done
