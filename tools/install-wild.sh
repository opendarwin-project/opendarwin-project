#!/usr/bin/env bash
set -euo pipefail

# Installs wild (https://github.com/theoparis/wild), this workspace's
# linker, to a stable PATH location. wild is a cargo crate, not a buck2
# target: `cargo install --git` is simpler than vendoring its (much larger
# than mold's) dependency tree through reindeer, and -- unlike buck2 --
# doesn't hit toolchains//:cxx's dependency-cycle problem (see
# toolchains/BUCK) in the first place.
#
# `macho` enables wild's Darwin/Mach-O output support, used by
# tools/build_frameworks.sh for this project's actual userland/Darwin
# binaries; upstream wild-linker/wild doesn't support Mach-O at all, hence
# the fork (Mach-O support lives on its `main` branch). Clang's Darwin
# driver dispatches `-fuse-ld=NAME` to a binary named `ld64.NAME` (falling
# back to bare `ld64`), not `ld.NAME` like its ELF/GNU driver does - wild
# itself also recognizes its Mach-O personality by argv[0] being exactly
# `ld64` (see PlatformKind::from_executable_name), so `ld64` is the name we
# actually invoke it under for Darwin targets (toolchains/BUCK's
# `:cxx-darwin` passes `-fuse-ld=ld64`); `ld.wild` remains for the ELF side.
#
# Usage:
#   tools/install-mold.sh [install-dir]   # default: ~/.local/bin

install_dir="${1:-$HOME/.local/bin}"

echo "==> installing wild"
cargo install --git https://github.com/theoparis/wild --branch push-umytlxkznurk --locked --features macho wild-linker

mkdir -p "$install_dir"
install -m 0755 "$HOME/.cargo/bin/wild" "$install_dir/wild"
ln -sf wild "$install_dir/ld.wild"
ln -sf wild "$install_dir/ld64"

echo "==> installed $("$install_dir/wild" --version) to $install_dir"
case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) echo "warning: $install_dir is not on PATH" >&2 ;;
esac
