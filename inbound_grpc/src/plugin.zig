const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

fn registerInboundGrpc(_: *abi.extension.KernelHandle_ABI, _: *const abi.KernelApiVTable_ABI) anyerror!void {}

pub const manifest = sdk.extension.Extension.define(.{
    .name = "inbound_grpc",
    .version = .{ .major = 2, .minor = 0, .patch = 1 },
    .register = registerInboundGrpc,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "inbound_grpc C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("inbound_grpc", manifest.nameSlice());
}
