const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

var spans_recorded: usize = 0;

fn onEvent(_: *abi.extension.SubscriberCtx_ABI, _: *const abi.TelemetryEvent_ABI) callconv(.c) void {
    spans_recorded += 1;
}

const sub_vtable = abi.TelemetrySubscriberVTable_ABI{
    .on_event = onEvent,
};

var sub_dummy: u8 = 0;

fn registerOpenTelemetry(
    kernel: *abi.extension.KernelHandle_ABI,
    api: *const abi.KernelApiVTable_ABI,
) anyerror!void {
    const rc = api.subscribe_telemetry(kernel, @ptrCast(&sub_dummy), &sub_vtable);
    if (rc != .ok) return error.SubscribeFailed;
}

pub const manifest = sdk.sdk.defineExtension(.{
    .name = "opentelemetry",
    .version = .{ .major = 1, .minor = 3, .patch = 0 },
    .register = registerOpenTelemetry,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "opentelemetry C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("opentelemetry", manifest.nameSlice());
}
