const std = @import("std");
const sdk = @import("parabellum_sdk");
const platform = @import("parabellum_platform");
const abi = sdk.abi;

extern "c" fn fflush(stream: *std.c.FILE) c_int;

var spans_recorded: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var write_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var otel_file: ?*std.c.FILE = null;
var otel_file_init: bool = false;
var otel_console: bool = false;

fn acquireLock() void {
    while (write_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn releaseLock() void {
    write_lock.store(false, .release);
}

fn ensureSinkInit() void {
    if (otel_file_init) return;
    otel_file_init = true;
    if (std.c.getenv("PARABELLUM_OTEL_CONSOLE")) |c| {
        const s = std.mem.span(c);
        otel_console = std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
    }
    if (std.c.getenv("PARABELLUM_OTEL_FILE")) |path| {
        if (path[0] != 0) {
            const p_slice = std.mem.span(path);
            if (std.fs.path.dirname(p_slice)) |dir| {
                platform.fs.nativeFs().mkdirAll(std.heap.c_allocator, dir) catch {};
            }
            otel_file = std.c.fopen(path, "a");
        }
    } else {
        otel_console = true;
    }
}

fn writeLine(line: []const u8, force_console: bool) void {
    acquireLock();
    defer releaseLock();
    ensureSinkInit();
    if (otel_file) |f| {
        _ = std.c.fwrite(line.ptr, 1, line.len, f);
        _ = fflush(f);
    }
    if (otel_console or force_console or otel_file == null) {
        std.debug.print("{s}", .{line});
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
    _ = spans_recorded.fetchAdd(1, .monotonic);
    var trace_buf: [32]u8 = undefined;
    var span_buf: [16]u8 = undefined;
    var parent_buf: [16]u8 = undefined;
    const trace_hex = formatHex(&ev.trace_id, &trace_buf);
    const span_hex = formatHex(&ev.span_id, &span_buf);
    const parent_hex = formatHex(&ev.parent_span_id, &parent_buf);

    var line_buf: [2048]u8 = undefined;
    var force_console = false;
    const line: []const u8 = switch (ev.kind) {
        .pipeline_start => std.fmt.bufPrint(
            &line_buf,
            "[OTEL] trace={s} span={s} event=pipeline_start input_bytes={d}\n",
            .{ trace_hex, span_hex, ev.count_b },
        ) catch return,
        .pipeline_end => std.fmt.bufPrint(
            &line_buf,
            "[OTEL] trace={s} span={s} event=pipeline_end duration_ms={d:.2} steps={d} halted={}\n",
            .{ trace_hex, span_hex, @as(f64, @floatFromInt(ev.duration_ns)) / 1_000_000.0, ev.count_a, ev.flags != 0 },
        ) catch return,
        .step_start => std.fmt.bufPrint(
            &line_buf,
            "[OTEL] trace={s} span={s} parent={s} event=step_start step={s} module={s} task={s} inputs={d}\n",
            .{ trace_hex, span_hex, parent_hex, ev.primary_name.toSlice(), ev.secondary_name.toSlice(), ev.tertiary_name.toSlice(), ev.count_a },
        ) catch return,
        .step_end => blk: {
            const st = ev.secondary_name.toSlice();
            if (std.mem.eql(u8, st, "error")) force_console = true;
            break :blk std.fmt.bufPrint(
                &line_buf,
                "[OTEL] trace={s} span={s} event=step_end step={s} status={s} duration_ms={d:.2} outputs={d}\n",
                .{ trace_hex, span_hex, ev.primary_name.toSlice(), st, @as(f64, @floatFromInt(ev.duration_ns)) / 1_000_000.0, ev.count_a },
            ) catch return;
        },
        .task_log => blk: {
            if (ev.flags >= 3) force_console = true;
            break :blk std.fmt.bufPrint(
                &line_buf,
                "[OTEL] trace={s} span={s} event=task_log step={s} level={d} msg={s}\n",
                .{ trace_hex, span_hex, ev.primary_name.toSlice(), ev.flags, ev.payload.toSlice() },
            ) catch return;
        },
        .filter_evaluated => std.fmt.bufPrint(
            &line_buf,
            "[OTEL] trace={s} span={s} event=filter_evaluated step={s} in={d} out={d} expr={s}\n",
            .{ trace_hex, span_hex, ev.primary_name.toSlice(), ev.count_a, ev.count_b, ev.tertiary_name.toSlice() },
        ) catch return,
        .router_decision => std.fmt.bufPrint(
            &line_buf,
            "[OTEL] trace={s} span={s} event=router_decision pipeline={s} router={s} target={s}\n",
            .{ trace_hex, span_hex, ev.primary_name.toSlice(), ev.secondary_name.toSlice(), ev.tertiary_name.toSlice() },
        ) catch return,
        else => return,
    };
    writeLine(line, force_console);
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

pub const manifest = sdk.extension.Extension.define(.{
    .name = "opentelemetry",
    .version = abi.SemVer_ABI.parse(@import("build_options").extension_version),
    .register = registerOpenTelemetry,
});

test "opentelemetry C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("opentelemetry", manifest.nameSlice());
}
