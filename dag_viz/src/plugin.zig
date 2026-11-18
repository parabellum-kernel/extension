const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

fn registerDagViz(_: *abi.extension.KernelHandle_ABI, _: *const abi.KernelApiVTable_ABI) anyerror!void {}

pub const manifest = sdk.sdk.defineExtension(.{
    .name = "dag_viz",
    .version = .{ .major = 2, .minor = 0, .patch = 1 },
    .register = registerDagViz,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "dag_viz C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("dag_viz", manifest.nameSlice());
}
