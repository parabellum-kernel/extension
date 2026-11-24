const std = @import("std");
const sdk = @import("parabellum_sdk");
const platform = @import("parabellum_platform");
const abi = sdk.abi;

extern "c" fn fflush(stream: *std.c.FILE) c_int;

/// Standalone C-ABI Trace JSONL Extension (zero dependency on `parabellum` core source).
var events_logged: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var write_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var trace_file: ?*std.c.FILE = null;
var trace_file_init: bool = false;

fn acquireLock() void {
    while (write_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn releaseLock() void {
    write_lock.store(false, .release);
}

fn ensureFileInit() void {
    if (trace_file_init) return;
    trace_file_init = true;
    if (std.c.getenv("PARABELLUM_TRACE_OUT")) |path| {
        if (path[0] != 0) {
            const p_slice = std.mem.span(path);
            if (std.fs.path.dirname(p_slice)) |dir| {
                platform.fs.nativeFs().mkdirAll(std.heap.c_allocator, dir) catch {};
            }
            trace_file = std.c.fopen(path, "a");
        }
    }
}

fn formatHex(bytes: []const u8, out: []u8) []const u8 {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out[0 .. bytes.len * 2];
}

fn onEvent(_: *abi.extension.SubscriberCtx_ABI, ev: *const abi.TelemetryEvent_ABI) callconv(.c) void {
    _ = events_logged.fetchAdd(1, .monotonic);
    var trace_buf: [32]u8 = undefined;
    var span_buf: [16]u8 = undefined;
    const trace_hex = formatHex(&ev.trace_id, &trace_buf);
    const span_hex = formatHex(&ev.span_id, &span_buf);

    var line_buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "{{\"kind\":\"{s}\",\"trace_id\":\"{s}\",\"span_id\":\"{s}\",\"ts_ns\":{d},\"duration_ns\":{d},\"primary\":\"{s}\",\"secondary\":\"{s}\",\"count_a\":{d},\"count_b\":{d}}}\n",
        .{
            @tagName(ev.kind),
            trace_hex,
            span_hex,
            ev.timestamp_ns,
            ev.duration_ns,
            ev.primary_name.toSlice(),
            ev.secondary_name.toSlice(),
            ev.count_a,
            ev.count_b,
        },
    ) catch return;

    acquireLock();
    defer releaseLock();
    ensureFileInit();
    if (trace_file) |f| {
        _ = std.c.fwrite(line.ptr, 1, line.len, f);
        _ = fflush(f);
    }
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

pub const manifest = sdk.extension.Extension.define(.{
    .name = "trace_jsonl",
    .version = abi.SemVer_ABI.parse(@import("build_options").extension_version),
    .register = registerTraceJsonl,
});

test "trace_jsonl C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("trace_jsonl", manifest.nameSlice());
}
