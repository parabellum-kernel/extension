const std = @import("std");
const sdk = @import("flowdata_sdk");
const abi = sdk.abi;

fn registerArtifact(_: *abi.extension.KernelHandle_ABI, _: *const abi.KernelApiVTable_ABI) anyerror!void {}

pub const manifest = sdk.sdk.defineExtension(.{
    .name = "artifact",
    .version = .{ .major = 0, .minor = 1, .patch = 0 },
    .register = registerArtifact,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "artifact C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("artifact", manifest.nameSlice());
}
