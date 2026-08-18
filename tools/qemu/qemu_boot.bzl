"""Rule producing a hermetic launcher that boots a freestanding aarch64
kernel ELF under QEMU's `virt` machine, using `rules_qemu`'s hermetic
qemu-system-aarch64 toolchain instead of relying on a system QEMU install."""

def _rlocationpath(ctx, file):
    """Runfiles-relative path for `file`, as expected by the Bash
    `rlocation` helper from @bazel_tools//tools/bash/runfiles."""
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return ctx.workspace_name + "/" + file.short_path

def _qemu_boot_impl(ctx):
    toolchain = ctx.toolchains["@rules_qemu//qemu:exec_toolchain_type"]
    qemu_system = toolchain.qemu_system
    data_anchor = toolchain.system_data_anchor
    kernel = ctx.executable.kernel

    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = launcher,
        is_executable = True,
        substitutions = {
            "{{DTB_ADDR}}": ctx.attr.dtb_addr,
            "{{KERNEL_RLOCATIONPATH}}": _rlocationpath(ctx, kernel),
            "{{QEMU_DATA_DIR_RLOCATIONPATH}}": _rlocationpath(ctx, data_anchor),
            "{{QEMU_SYSTEM_RLOCATIONPATH}}": _rlocationpath(ctx, qemu_system),
        },
    )

    runfiles = ctx.runfiles(files = [qemu_system, kernel] + toolchain.system_data_files.to_list())
    runfiles = runfiles.merge(ctx.attr._bash_runfiles[DefaultInfo].default_runfiles)

    return [DefaultInfo(
        executable = launcher,
        runfiles = runfiles,
    )]


qemu_boot = rule(
    implementation = _qemu_boot_impl,
    attrs = {
        "kernel": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
            doc = "Freestanding aarch64 kernel ELF to boot (e.g. //src/kernel:kernel).",
        ),
        "dtb_addr": attr.string(
            default = "0x40680000",
            doc = ("Load address for the QEMU-dumped virt DTB; must match " +
                   "src/kernel/src/devicetree.rs's discover() fallback " +
                   "(mmu::KERNEL_LOAD_ADDR + mmu::KERNEL_IMAGE_MAX_LEN)."),
        ),
        "_template": attr.label(
            default = ":qemu_boot.sh.tpl",
            allow_single_file = True,
        ),
        "_bash_runfiles": attr.label(default = "@bazel_tools//tools/bash/runfiles"),
    },
    toolchains = ["@rules_qemu//qemu:exec_toolchain_type"],
    executable = True,
    doc = ("Boots `kernel` under a hermetic qemu-system-aarch64 `virt` " +
           "machine: `bazel run //tools/qemu:kernel -- [-d ROOTFS_IMG] " +
           "[-g] [-- QEMU_ARGS...]`."),
)
