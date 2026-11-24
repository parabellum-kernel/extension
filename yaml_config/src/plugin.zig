const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const root = @import("root.zig");

var loader_ctx_marker: u8 = 0;

fn loadPipelineAbi(
    _: *abi.extension.ConfigLoaderCtx_ABI,
    pipeline_path: abi.Slice_ABI,
    builder: *abi.extension.PipelineBuilderHandle_ABI,
    builder_vtable: *const abi.extension.PipelineBuilderVTable_ABI,
) callconv(.c) abi.HostError_ABI {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();

    root.loadPipelineWithBuilder(arena.allocator(), pipeline_path.toSlice(), builder, builder_vtable) catch |err| switch (err) {
        error.FileNotFound => return .invalid_argument,
        error.OutOfMemory => return .out_of_memory,
        else => return .internal_error,
    };

    return .ok;
}

const config_loader_vtable = abi.extension.ConfigLoaderVTable_ABI{
    .load_pipeline = loadPipelineAbi,
};

fn registerExtension(
    kernel: *abi.extension.KernelHandle_ABI,
    api: *const abi.KernelApiVTable_ABI,
    out_ext_ctx: *?*anyopaque,
) callconv(.c) abi.HostError_ABI {
    out_ext_ctx.* = &loader_ctx_marker;
    if (api.register_config_loader) |reg_fn| {
        return reg_fn(
            kernel,
            "yaml",
            @ptrCast(&loader_ctx_marker),
            &config_loader_vtable,
        );
    }
    return .ok;
}

pub const manifest = abi.ExtensionManifest_ABI{
    .abi_version = abi.EXTENSION_ABI_VERSION,
    .min_engine_version = abi.common.SDK_VERSION,
    .extension_name = "yaml_config",
    .extension_version = .{ .major = 0, .minor = 1, .patch = 0 },
    .register = registerExtension,
    .deinit = null,
};

comptime {
    @export(&manifest, .{ .name = @import("plugin_options").manifest_symbol, .linkage = .strong });
}
