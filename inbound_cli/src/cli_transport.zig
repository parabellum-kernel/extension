const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

pub fn printStdout(msg: []const u8) void {
    if (msg.len == 0) return;
    _ = std.c.write(std.c.STDOUT_FILENO, msg.ptr, msg.len);
}

pub fn printStderr(msg: []const u8) void {
    if (msg.len == 0) return;
    _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
}

pub const CliRequest = struct {
    route: []const u8,
    pipeline_path: []const u8 = "",
    payload: []const u8 = "",
    is_custom: bool = false,
};

pub fn parseArgv(argv: [*]const abi.Slice_ABI, argc: usize) ?CliRequest {
    if (argc < 2) return null;
    const cmd = argv[1].toSlice();

    var pipeline_path: []const u8 = "";
    var payload: []const u8 = "";
    var is_custom = false;

    if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "validate")) {
        if (argc >= 3) {
            pipeline_path = argv[2].toSlice();
        }
    } else {
        is_custom = true;
        if (argc >= 3) {
            payload = argv[2].toSlice();
        }
    }

    return .{
        .route = cmd,
        .pipeline_path = pipeline_path,
        .payload = payload,
        .is_custom = is_custom,
    };
}
