const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const cli = @import("cli_transport.zig");

var transport_ctx_marker: u8 = 0;

fn cliServe(
    _: *abi.extension.TransportCtx_ABI,
    _: abi.Slice_ABI,
    _: abi.Slice_ABI,
    _: *anyopaque,
    _: abi.extension.HostDispatchFn_ABI,
) callconv(.c) abi.HostError_ABI {
    // Synchronous CLI requires serve_args with argv
    return .not_supported;
}

fn cliServeArgs(
    _: *abi.extension.TransportCtx_ABI,
    argv: [*]const abi.Slice_ABI,
    argc: usize,
    host_dispatcher: *anyopaque,
    dispatch_fn: abi.extension.HostDispatchFn_ABI,
) callconv(.c) abi.HostError_ABI {
    const req_parsed = cli.parseArgv(argv, argc) orelse {
        cli.printStderr("Usage: parabellum-engine <command> [options]\n");
        return .ok;
    };

    var args_buf: [128]u8 = undefined;
    const args_json = std.fmt.bufPrint(
        &args_buf,
        "{{\"custom\":{}}}",
        .{req_parsed.is_custom},
    ) catch return .out_of_memory;

    const abi_req = abi.extension.InboundRequest_ABI{
        .command_or_route = abi.Slice_ABI.from(req_parsed.route),
        .pipeline_yaml_path = abi.Slice_ABI.from(req_parsed.pipeline_path),
        .payload = abi.Slice_ABI.from(req_parsed.payload),
        .args_json = abi.Slice_ABI.from(args_json),
    };

    var abi_resp: abi.extension.InboundResponse_ABI = .{ .status_code = 500, .body = abi.Slice_ABI.empty };
    const rc = dispatch_fn(host_dispatcher, &abi_req, &abi_resp);
    if (rc != .ok) {
        cli.printStderr("Error: Dispatch failed\n");
        return rc;
    }

    const body = abi_resp.body.toSlice();
    if (abi_resp.status_code >= 200 and abi_resp.status_code < 300) {
        cli.printStdout(body);
        if (body.len > 0 and body[body.len - 1] != '\n') {
            cli.printStdout("\n");
        }
    } else {
        cli.printStderr(body);
        if (body.len > 0 and body[body.len - 1] != '\n') {
            cli.printStderr("\n");
        }
    }

    return .ok;
}

fn cliDeinit(_: *abi.extension.TransportCtx_ABI) callconv(.c) void {}

const transport_vtable = abi.InboundTransportVTable_ABI{
    .serve = cliServe,
    .deinit = cliDeinit,
    .serve_args = cliServeArgs,
};

fn registerInboundCli(kernel: *abi.extension.KernelHandle_ABI, api: *const abi.KernelApiVTable_ABI) anyerror!void {
    const tctx: *abi.extension.TransportCtx_ABI = @ptrCast(&transport_ctx_marker);
    const rc = api.register_inbound_transport(kernel, "cli", tctx, &transport_vtable);
    if (rc != .ok) return error.TransportRegistrationFailed;
}

pub const manifest = sdk.sdk.defineExtension(.{
    .name = "inbound_cli",
    .version = .{ .major = 1, .minor = 3, .patch = 0 },
    .register = registerInboundCli,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}
