# mojo-parity

Bit-exact compatibility kernels for porting Go and Python services to Mojo, extracted from production ports
(trading bots and their data jobs). Every module was checked differentially against the original runtime.

| package | what it reproduces |
|---|---|
| `p2.gofmt`, `p2.gotime`, `p2.goflag`, `p2.jraw`, `p2.jsonw`, `p2.gojsonscan` | Go `strconv`/`fmt` floats, `time` (zones, layouts, Duration), `flag`, `encoding/json` read/write |
| `p2.pyjson` | Python `json.loads/dumps` (key order, `float.__repr__`, ensure_ascii, sort_keys) |
| `p2.sha256`, `p2.hmac` | SHA-1/256/512, HMAC, base32/TOTP |
| `net.http`, `net.sock` | HTTP/1.1 client (keep-alive, chunked, TLS via system OpenSSL) |
| `dec.decimal` | shopspring/decimal value semantics (Div=16 places half-away, RoundFloor/Ceil, NewFromFloat, String) |
| `bg.bigint` | small arbitrary-precision integers |
| `pynp.np` | numpy float64 reductions (pairwise contiguous sums, sequential outer-axis sums, var/std), pandas average pct-rank |
| `pynp.lgbm` | LightGBM text-model predictor (numerical splits; regression/lambdarank raw scores) |

Use: add as a git submodule and pass `-I <path>/src` to `mojo build` (build with `--fp-mode contract=off`
so float code matches Go/numpy op for op). `pixi run test-decimal` fuzzes `dec.decimal` against Go.
