const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const http = @import("http_transport.zig");

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

fn httpServe(
    _: *abi.extension.TransportCtx_ABI,
    listen_addr: abi.Slice_ABI,
    pipeline_path: abi.Slice_ABI,
    host_dispatcher: *anyopaque,
    dispatch_fn: abi.extension.HostDispatchFn_ABI,
) callconv(.c) abi.HostError_ABI {
    var server = http.HttpServer.init(
        std.heap.c_allocator,
        http.parseListenAddress(listen_addr.toSlice(), pipeline_path.toSlice()),
    );
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
    .version = .{ .major = 2, .minor = 0, .patch = 1 },
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
}
