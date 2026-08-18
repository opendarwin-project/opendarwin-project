"""Outgoing platform transition so cross-platform targets (kernel, userland)
build under their target platform without requiring `--platforms` on the
command line, keeping a single analysis cache across host-tool and
cross-compiled targets in the same invocation."""

def _platform_transition_impl(settings, attr):
    return {"//command_line_option:platforms": [str(attr.platform)]}

platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _platform_transition_binary_impl(ctx):
    actual = ctx.attr.actual[0]
    default_info = actual[DefaultInfo]
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = default_info.files_to_run.executable,
        is_executable = True,
    )
    providers = [DefaultInfo(
        executable = executable,
        files = depset([executable]),
        runfiles = default_info.default_runfiles,
    )]
    if OutputGroupInfo in actual:
        providers.append(actual[OutputGroupInfo])
    return providers

_platform_transition_binary = rule(
    implementation = _platform_transition_binary_impl,
    attrs = {
        "actual": attr.label(cfg = platform_transition, mandatory = True, executable = True),
        "platform": attr.label(mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    executable = True,
)

def _platform_transition_library_impl(ctx):
    actual = ctx.attr.actual[0]
    providers = [actual[DefaultInfo]]
    if OutputGroupInfo in actual:
        providers.append(actual[OutputGroupInfo])
    return providers

_platform_transition_library = rule(
    implementation = _platform_transition_library_impl,
    attrs = {
        "actual": attr.label(cfg = platform_transition, mandatory = True),
        "platform": attr.label(mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def platform_binary(name, platform, actual_name = None, **kwargs):
    """Re-exposes the `rust_binary` at `actual_name` (default `_{name}`) as
    `name`, built under `platform` regardless of the command-line
    `--platforms` value."""
    _platform_transition_binary(
        name = name,
        actual = ":" + (actual_name or ("_" + name)),
        platform = platform,
        visibility = kwargs.pop("visibility", None),
    )

def platform_library(name, platform, actual_name = None, **kwargs):
    """Like `platform_binary`, for non-executable targets (e.g. rust_library).
    Only useful for standalone `bazel build`; do not depend on this wrapper
    from other rust targets - the forwarded `DefaultInfo` does not carry the
    Rust-specific providers `deps` resolution needs. Depend on `actual_name`
    (or the plain, untransitioned target) instead."""
    _platform_transition_library(
        name = name,
        actual = ":" + (actual_name or ("_" + name)),
        platform = platform,
        visibility = kwargs.pop("visibility", None),
    )

def _exec_platform_transition_impl(settings, attr):
    # Empty list un-sets `--platforms`, falling back to Bazel's normal
    # auto-detected exec/host platform.
    return {"//command_line_option:platforms": []}

exec_platform_transition = transition(
    implementation = _exec_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _exec_platform_file_impl(ctx):
    return [ctx.attr.actual[0][DefaultInfo]]

_exec_platform_file = rule(
    implementation = _exec_platform_file_impl,
    attrs = {
        "actual": attr.label(cfg = exec_platform_transition, mandatory = True, allow_single_file = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def exec_platform_file(name, actual, **kwargs):
    """Re-exposes the file at `actual` as `name`, built under Bazel's normal
    exec/host platform even when depended on from a target that carries an
    outgoing `platform_binary`/`platform_library` transition (e.g. embedding
    a host-built genrule output as `compile_data` of a freestanding
    aarch64-unknown-none crate, which would otherwise try to resolve
    build-time toolchains - like Python, for the ramdisk image builder - for
    that freestanding target platform and fail)."""
    _exec_platform_file(
        name = name,
        actual = actual,
        visibility = kwargs.pop("visibility", None),
    )
