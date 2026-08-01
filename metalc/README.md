# metalc — OpenMetal AIR compiler

IR-first Metal/AIR compiler (pliron dialects → `AirModule` → typed-pointer
bitcode → `.metallib`). Validated on host Metal.

## Pipeline

```text
dialect-metal → metal-transforms → metal-lower → AirModule
  → emit_bitcode (pure Rust) → metallib MTLB pack → MTLDevice
```

## Quick start

```bash
cargo run -p metalc -- dump
cargo run -p metalc -- emit-ll -o /tmp/add_one.ll
cargo run -p metalc -- emit-metallib -o /tmp/add_one.metallib
cargo test --workspace
```

Host compute proof: `cargo test -p metalc-host-test` (macOS).

## Layout

| Crate | Role |
|-------|------|
| `metallib` | MTLB container R/W |
| `air-bitcode` | `AirModule`, LLVM IR dump, **typed-pointer bitcode writer** |
| `dialect-metal` / `dialect-air` | pliron dialects |
| `metal-lower` / `metal-transforms` | Lowering / passes |
| `metalc` | CLI |
| `metalc-host-test` | Host Metal smoke test |

Workspace root is the repo root (`Cargo.toml`). Goldens live in `/testdata`.
