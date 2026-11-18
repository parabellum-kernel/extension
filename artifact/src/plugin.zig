const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

fn registerArtifact(_: *abi.extension.KernelHandle_ABI, _: *const abi.KernelApiVTable_ABI) anyerror!void {}

pub const manifest = sdk.sdk.defineExtension(.{
    .name = "artifact",
    .version = .{ .major = 1, .minor = 3, .patch = 1 },
    .register = registerArtifact,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "artifact C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("artifact", manifest.nameSlice());
}
