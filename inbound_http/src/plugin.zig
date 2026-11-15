const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

fn registerInboundHttp(_: *abi.extension.KernelHandle_ABI, _: *const abi.KernelApiVTable_ABI) anyerror!void {}

pub const manifest = sdk.sdk.defineExtension(.{
    .name = "inbound_http",
    .version = .{ .major = 0, .minor = 1, .patch = 0 },
    .register = registerInboundHttp,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "inbound_http C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("inbound_http", manifest.nameSlice());
}
