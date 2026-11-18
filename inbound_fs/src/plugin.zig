const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const watcher = @import("fs_watcher.zig");

const FsCtx = struct {
    alloc: std.mem.Allocator,
    pipeline_path: []const u8,
    partition: []const u8,
    host_dispatcher: *anyopaque,
    dispatch: abi.extension.HostDispatchFn_ABI,
};

fn onFileChanged(raw_ctx: *anyopaque, full_path: []const u8, file_name: []const u8) void {
    const fc: *FsCtx = @ptrCast(@alignCast(raw_ctx));
    const json_payload = std.fmt.allocPrint(
        fc.alloc,
        "{{\"pipeline\":\"sync_diff\",\"partition\":\"{s}\",\"name\":\"{s}\",\"source_path\":\"{s}\"}}",
        .{ fc.partition, file_name, full_path },
    ) catch return;
    defer fc.alloc.free(json_payload);

    const abi_req = abi.extension.InboundRequest_ABI{
        .command_or_route = abi.Slice_ABI.from("run"),
        .pipeline_yaml_path = abi.Slice_ABI.from(fc.pipeline_path),
        .payload = abi.Slice_ABI.from(json_payload),
        .args_json = abi.Slice_ABI.from("{\"input\":\"job_json\",\"custom\":false,\"load_shared_modules\":true}"),
    };
    var abi_resp: abi.extension.InboundResponse_ABI = .{ .status_code = 500, .body = abi.Slice_ABI.empty };
    _ = fc.dispatch(fc.host_dispatcher, &abi_req, &abi_resp);
}

var transport_ctx_marker: u8 = 0;

fn fsServe(
    _: *abi.extension.TransportCtx_ABI,
    listen_addr: abi.Slice_ABI,
    pipeline_path: abi.Slice_ABI,
    host_dispatcher: *anyopaque,
    dispatch_fn: abi.extension.HostDispatchFn_ABI,
) callconv(.c) abi.HostError_ABI {
    const target = watcher.parseWatchTarget(listen_addr.toSlice());
    const alloc = std.heap.c_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var w = watcher.FsWatcher.init(alloc, target.dir_path);
    defer w.deinit();

    var fctx = FsCtx{
        .alloc = alloc,
        .pipeline_path = pipeline_path.toSlice(),
        .partition = target.partition,
        .host_dispatcher = host_dispatcher,
        .dispatch = dispatch_fn,
    };

    w.watchLoop(io, &fctx, onFileChanged) catch return .io_error;
    return .ok;
}

fn fsDeinit(_: *abi.extension.TransportCtx_ABI) callconv(.c) void {}

const fs_vtable = abi.InboundTransportVTable_ABI{
    .serve = fsServe,
    .deinit = fsDeinit,
};

fn registerExt(kernel: *abi.extension.KernelHandle_ABI, api: *const abi.KernelApiVTable_ABI) anyerror!void {
    const rc = api.register_inbound_transport(kernel, "fs", @ptrCast(&transport_ctx_marker), &fs_vtable);
    if (rc != .ok) return error.RegisterInboundTransportFailed;
}

pub const manifest = sdk.sdk.defineExtension(.{
    .name = "inbound_fs",
    .version = .{ .major = 2, .minor = 0, .patch = 1 },
    .register = registerExt,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "inbound_fs watcher" {
    _ = watcher;
}
