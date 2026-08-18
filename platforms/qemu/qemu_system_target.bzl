"""Build setting selecting which `rules_qemu` system-mode guest toolchain to
register (see MODULE.bazel's `qemu.system_toolchain` tag). Only one guest
(aarch64, for src/kernel's `virt`-machine target) is wired today; this is a
plain string flag rather than a hardcoded `config_setting` so a second guest
can be added later without touching MODULE.bazel's toolchain registration."""

def _qemu_system_target_impl(_ctx):
    return []

qemu_system_target = rule(
    implementation = _qemu_system_target_impl,
    build_setting = config.string(flag = True),
)
