const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

/// Standalone C-ABI Trace JSONL Extension (zero dependency on `parabellum` core source).
var events_logged: usize = 0;

fn onEvent(_: *abi.extension.SubscriberCtx_ABI, ev: *const abi.TelemetryEvent_ABI) callconv(.c) void {
    _ = ev;
    events_logged += 1;
}

const sub_vtable = abi.TelemetrySubscriberVTable_ABI{
    .on_event = onEvent,
};

var sub_dummy: u8 = 0;

fn registerTraceJsonl(
    kernel: *abi.extension.KernelHandle_ABI,
    api: *const abi.KernelApiVTable_ABI,
) anyerror!void {
    const rc = api.subscribe_telemetry(kernel, @ptrCast(&sub_dummy), &sub_vtable);
    if (rc != .ok) return error.SubscribeFailed;
}

pub const manifest = sdk.sdk.defineExtension(.{
    .name = "trace_jsonl",
    .version = .{ .major = 1, .minor = 3, .patch = 1 },
    .register = registerTraceJsonl,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "trace_jsonl C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("trace_jsonl", manifest.nameSlice());
}
