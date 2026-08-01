# metalc — OpenMetal AIR compiler

IR-first Metal/AIR compiler (pliron dialects → `AirModule` → typed-pointer
bitcode → `.metallib`), plus a tiny MSL frontend. Validated on host Metal.

## Pipeline

```text
MSL subset ──► msl-frontend ─┐
                             ├─► dialect-metal → metal-transforms → metal-lower
built-in IR ─────────────────┘         → AirModule → emit_bitcode → metallib
```

## Quick start

```bash
cargo run -p metalc -- dump
cargo run -p metalc -- parse testdata/add_one.metal
cargo run -p metalc -- emit-ll testdata/add_one.metal -o /tmp/add_one.ll
cargo run -p metalc -- emit-metallib testdata/add_one.metal -o /tmp/add_one.metallib
cargo test --workspace
```

Host compute proof: `cargo test -p metalc-host-test` (macOS).

## Layout

| Crate | Role |
|-------|------|
| `metallib` | MTLB container R/W |
| `air-bitcode` | `AirModule`, LLVM IR dump, **typed-pointer bitcode writer** |
| `msl-frontend` | MSL subset parser + `annotate-snippets` diagnostics |
| `dialect-metal` / `dialect-air` | pliron dialects |
| `metal-lower` / `metal-transforms` | Lowering / passes |
| `metalc` | CLI |
| `metalc-host-test` | Host Metal smoke test |

Workspace root is the repo root (`Cargo.toml`). Goldens live in `/testdata`.

## MSL subset (MVP)

Accepts `testdata/add_one.metal`-shaped kernels: optional `#include` /
`using namespace metal;`, one `kernel void` with `device` float buffers,
`uint [[thread_position_in_grid]]`, and a single `out[tid] = in[tid] + 1.0f`
assignment. Unsupported shapes get rustc-style spanned errors.
