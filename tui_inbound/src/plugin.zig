const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const inbound = sdk.transport.inbound;
const root = @import("root.zig");

var transport_ctx_marker: u8 = 0;
var global_event_ring = root.EventRing{};
var global_catalog_parsed: ?std.json.Parsed(sdk.capabilities.CapabilityCatalog) = null;
var global_kernel: ?*abi.extension.KernelHandle_ABI = null;
var global_api: ?*const abi.KernelApiVTable_ABI = null;

fn onTelemetryEvent(_: *abi.extension.SubscriberCtx_ABI, ev: *const abi.TelemetryEvent_ABI) callconv(.c) void {
    global_event_ring.pushAbiEvent(ev);
}

const telemetry_sub_vtable = abi.TelemetrySubscriberVTable_ABI{
    .on_event = onTelemetryEvent,
};

fn tuiServe(
    _: *abi.extension.TransportCtx_ABI,
    _: abi.Slice_ABI,
    _: abi.Slice_ABI,
    host_dispatcher: *anyopaque,
    dispatch_fn: abi.extension.HostDispatchFn_ABI,
) callconv(.c) abi.HostError_ABI {
    const alloc = std.heap.c_allocator;
    if (global_kernel) |k| {
        if (global_api) |api| {
            if (inbound.fetchCapabilityCatalog(alloc, k, api) catch null) |parsed| {
                if (global_catalog_parsed) |*old| old.deinit();
                global_catalog_parsed = parsed;
            }
        }
    }
    const catalog: sdk.capabilities.CapabilityCatalog = if (global_catalog_parsed) |cp|
        cp.value
    else
        .{
            .id = "parabellum",
            .name = "Parabellum TUI",
            .version = "0.1.0",
        };

    const dispatcher = inbound.HostDispatcher{
        .ptr = host_dispatcher,
        .dispatch_fn = dispatch_fn,
    };

    var app = root.TuiApp.init(alloc, catalog, &global_event_ring, .{}) catch return .out_of_memory;
    defer app.deinit();

    app.run(dispatcher) catch |err| switch (err) {
        error.NotATerminal => return .invalid_argument,
        else => return .internal_error,
    };
    return .ok;
}

fn tuiDeinit(_: *abi.extension.TransportCtx_ABI) callconv(.c) void {
    if (global_catalog_parsed) |*old| {
        old.deinit();
        global_catalog_parsed = null;
    }
}

const tui_vtable = abi.InboundTransportVTable_ABI{
    .serve = tuiServe,
    .deinit = tuiDeinit,
};

fn registerTuiInbound(kernel: *abi.extension.KernelHandle_ABI, api: *const abi.KernelApiVTable_ABI) anyerror!void {
    global_kernel = kernel;
    global_api = api;
    if (inbound.fetchCapabilityCatalog(std.heap.c_allocator, kernel, api) catch null) |parsed| {
        if (global_catalog_parsed) |*old| old.deinit();
        global_catalog_parsed = parsed;
    }
    _ = api.subscribe_telemetry(kernel, @ptrCast(&transport_ctx_marker), &telemetry_sub_vtable);
    const rc = api.register_inbound_transport(
        kernel,
        "tui",
        @ptrCast(&transport_ctx_marker),
        &tui_vtable,
    );
    if (rc != .ok) return error.RegisterInboundTransportFailed;

    const rc2 = api.register_inbound_transport(
        kernel,
        "tui_inbound",
        @ptrCast(&transport_ctx_marker),
        &tui_vtable,
    );
    if (rc2 != .ok) return error.RegisterInboundTransportFailed;
}

pub const manifest = sdk.extension.Extension.define(.{
    .name = "tui_inbound",
    .version = abi.SemVer_ABI.parse(@import("build_options").extension_version),
    .register = registerTuiInbound,
});

comptime {
    @export(&manifest, .{ .name = @import("plugin_options").manifest_symbol, .linkage = .strong });
}

test "tui_inbound C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("tui_inbound", manifest.nameSlice());
}

test {
    _ = root;
}
