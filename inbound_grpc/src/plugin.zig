const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

fn registerInboundGrpc(_: *abi.extension.KernelHandle_ABI, _: *const abi.KernelApiVTable_ABI) anyerror!void {}

pub const manifest = sdk.extension.Extension.define(.{
    .name = "inbound_grpc",
    .version = abi.SemVer_ABI.parse(@import("build_options").extension_version),
    .register = registerInboundGrpc,
});

comptime {
    @export(&manifest, .{ .name = @import("plugin_options").manifest_symbol, .linkage = .strong });
}

test "inbound_grpc C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("inbound_grpc", manifest.nameSlice());
}
