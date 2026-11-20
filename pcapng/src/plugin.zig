const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

var packets_captured: usize = 0;

fn onEvent(_: *abi.extension.SubscriberCtx_ABI, ev: *const abi.TelemetryEvent_ABI) callconv(.c) void {
    if (ev.kind == .outbound_wire_packet) packets_captured += 1;
}

const sub_vtable = abi.TelemetrySubscriberVTable_ABI{
    .on_event = onEvent,
};

var sub_dummy: u8 = 0;

fn registerPcapng(
    kernel: *abi.extension.KernelHandle_ABI,
    api: *const abi.KernelApiVTable_ABI,
) anyerror!void {
    const rc = api.subscribe_telemetry(kernel, @ptrCast(&sub_dummy), &sub_vtable);
    if (rc != .ok) return error.SubscribeFailed;
}

pub const manifest = sdk.extension.Extension.define(.{
    .name = "pcapng",
    .version = .{ .major = 2, .minor = 0, .patch = 3 },
    .register = registerPcapng,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "pcapng C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("pcapng", manifest.nameSlice());
}
