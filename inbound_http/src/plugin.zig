const std = @import("std");
const sdk = @import("parabellum_sdk");
const platform = @import("parabellum_platform");
const abi = sdk.abi;
const http = @import("http_transport.zig");
const cap_router = @import("capability_router.zig");

/// Host dispatcher handle received through the C-ABI `serve` call.
const HostCtx = struct {
    host_dispatcher: *anyopaque,
    dispatch: abi.extension.HostDispatchFn_ABI,
};

/// Forwards an HTTP-level request to the host over the C-ABI.
/// Extra options (input kind, shared modules) travel in `args_json`.
fn abiDispatch(ctx: *anyopaque, req: http.Request) anyerror!http.Response {
    const hc: *HostCtx = @ptrCast(@alignCast(ctx));

    var args_buf: [128]u8 = undefined;
    const args_json = try std.fmt.bufPrint(
        &args_buf,
        "{{\"input\":\"{s}\",\"custom\":{},\"load_shared_modules\":{}}}",
        .{ @tagName(req.input_kind), req.is_custom, req.load_shared_modules },
    );

    const abi_req = abi.extension.InboundRequest_ABI{
        .command_or_route = abi.Slice_ABI.from(req.route),
        .pipeline_yaml_path = abi.Slice_ABI.from(req.pipeline_path),
        .payload = abi.Slice_ABI.from(req.payload),
        .args_json = abi.Slice_ABI.from(args_json),
    };
    var abi_resp: abi.extension.InboundResponse_ABI = .{ .status_code = 500, .body = abi.Slice_ABI.empty };
    if (hc.dispatch(hc.host_dispatcher, &abi_req, &abi_resp) != .ok) return error.HostDispatchFailed;

    return .{
        .status_code = if (abi_resp.status_code > 0) @intCast(abi_resp.status_code) else 500,
        .ok = abi_resp.status_code >= 200 and abi_resp.status_code < 300,
        .body = abi_resp.body.toSlice(),
    };
}

var transport_ctx_marker: u8 = 0;
var global_event_ring = cap_router.EventRing{};
var global_catalog_parsed: ?std.json.Parsed(sdk.capabilities.CapabilityCatalog) = null;

fn onTelemetryEvent(_: *abi.extension.SubscriberCtx_ABI, ev: *const abi.TelemetryEvent_ABI) callconv(.c) void {
    global_event_ring.pushAbiEvent(ev);
}

const telemetry_sub_vtable = abi.TelemetrySubscriberVTable_ABI{
    .on_event = onTelemetryEvent,
};

fn httpServe(
    _: *abi.extension.TransportCtx_ABI,
    listen_addr: abi.Slice_ABI,
    pipeline_path: abi.Slice_ABI,
    host_dispatcher: *anyopaque,
    dispatch_fn: abi.extension.HostDispatchFn_ABI,
) callconv(.c) abi.HostError_ABI {
    var cfg = http.parseListenAddress(listen_addr.toSlice(), pipeline_path.toSlice());
    cfg.event_ring = &global_event_ring;
    if (global_catalog_parsed) |cp| cfg.catalog = cp.value;
    const auth_tok = platform.env.nativeEnv().getEnv(std.heap.c_allocator, "PARABELLUM_HTTP_TOKEN");
    defer if (auth_tok) |t| std.heap.c_allocator.free(t);
    if (auth_tok) |t| {
        cfg.auth_token = t;
    }
    var server = http.HttpServer.init(std.heap.c_allocator, cfg);
    var hc = HostCtx{ .host_dispatcher = host_dispatcher, .dispatch = dispatch_fn };
    server.serveLoop(.{ .ctx = &hc, .func = abiDispatch }) catch return .io_error;
    return .ok;
}

fn httpDeinit(_: *abi.extension.TransportCtx_ABI) callconv(.c) void {}

const http_vtable = abi.InboundTransportVTable_ABI{
    .serve = httpServe,
    .deinit = httpDeinit,
};

fn registerInboundHttp(kernel: *abi.extension.KernelHandle_ABI, api: *const abi.KernelApiVTable_ABI) anyerror!void {
    if (sdk.transport.inbound.fetchCapabilityCatalog(std.heap.c_allocator, kernel, api) catch null) |parsed| {
        if (global_catalog_parsed) |*old| old.deinit();
        global_catalog_parsed = parsed;
    }
    _ = api.subscribe_telemetry(kernel, @ptrCast(&transport_ctx_marker), &telemetry_sub_vtable);
    const rc = api.register_inbound_transport(
        kernel,
        "http",
        @ptrCast(&transport_ctx_marker),
        &http_vtable,
    );
    if (rc != .ok) return error.RegisterInboundTransportFailed;
}

pub const manifest = sdk.extension.Extension.define(.{
    .name = "inbound_http",
    .version = .{ .major = 2, .minor = 0, .patch = 3 },
    .register = registerInboundHttp,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "inbound_http C-ABI extension manifest" {
    try std.testing.expectEqual(abi.EXTENSION_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("inbound_http", manifest.nameSlice());
}

test {
    _ = http;
    _ = cap_router;
}
