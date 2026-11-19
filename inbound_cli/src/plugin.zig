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
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var req_parsed = cli.parseArgv(alloc, argv, argc) catch |err| {
        var err_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "CLI parse error: {s}\n", .{@errorName(err)}) catch "CLI parse error\n";
        cli.printStderr(msg);
        return .invalid_argument;
    };
    defer req_parsed.deinit(alloc);

    switch (req_parsed.action) {
        .help => {
            const help_text = cli.cli_app.formatHelp(alloc, req_parsed.help_command) catch return .out_of_memory;
            cli.printStdout(help_text);
            return .ok;
        },
        .version => {
            cli.printStdout(cli.cli_app.spec.name ++ " " ++ cli.cli_app.spec.version ++ "\n");
            return .ok;
        },
        .run => {},
    }

    const abi_req = abi.extension.InboundRequest_ABI{
        .command_or_route = abi.Slice_ABI.from(req_parsed.route),
        .pipeline_yaml_path = abi.Slice_ABI.from(req_parsed.pipeline_path),
        .payload = abi.Slice_ABI.from(req_parsed.payload),
        .args_json = abi.Slice_ABI.from(req_parsed.args_json),
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

pub const manifest = sdk.extension.Extension.define(.{
    .name = "inbound_cli",
    .version = .{ .major = 2, .minor = 0, .patch = 2 },
    .register = registerInboundCli,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}
