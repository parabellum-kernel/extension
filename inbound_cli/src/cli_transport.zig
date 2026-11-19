const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const cli = @import("cli_builder.zig");

pub const BuiltinCommand = enum {
    run,
    validate,
};

pub const CliOption = enum {
    pipeline,
    payload,
    verbose,
    json,
};

pub const cli_app = cli.CliApp.fromSpec(.{
    .name = "parabellum-engine",
    .version = "2.0.2",
    .description = "Parabellum microkernel CLI transport",
    .allow_unknown_commands = true,
    .global_options = &.{
        cli.OptionSpec.fromEnum(CliOption.verbose, null, .flag, null, "Enable verbose diagnostic output"),
        cli.OptionSpec.fromEnum(CliOption.json, null, .flag, null, "Emit JSON formatted output"),
    },
    .commands = &.{
        cli.CommandSpec.fromEnum(
            BuiltinCommand.run,
            "Execute a pipeline YAML/AST",
            "<pipeline>",
            &.{
                cli.OptionSpec.fromEnum(CliOption.pipeline, 'p', .value, "<path>", "Path to pipeline YAML"),
                cli.OptionSpec.fromEnum(CliOption.payload, 'd', .value, "<data>", "Input payload data"),
            },
        ),
        cli.CommandSpec.fromEnum(
            BuiltinCommand.validate,
            "Validate a pipeline definition without running it",
            "<pipeline>",
            &.{
                cli.OptionSpec.fromEnum(CliOption.pipeline, 'p', .value, "<path>", "Path to pipeline YAML"),
            },
        ),
    },
});

pub fn printStdout(msg: []const u8) void {
    if (msg.len == 0) return;
    _ = std.c.write(std.c.STDOUT_FILENO, msg.ptr, msg.len);
}

pub fn printStderr(msg: []const u8) void {
    if (msg.len == 0) return;
    _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
}

pub const CliRequest = struct {
    action: cli.CliAction,
    help_command: ?[]const u8 = null,
    route: []const u8 = "",
    pipeline_path: []const u8 = "",
    payload: []const u8 = "",
    is_custom: bool = false,
    args_json: []u8,

    pub fn deinit(self: *CliRequest, alloc: std.mem.Allocator) void {
        alloc.free(self.args_json);
    }
};

fn isBuiltinCommand(name: []const u8) bool {
    return std.meta.stringToEnum(BuiltinCommand, name) != null;
}

pub fn parseArgv(alloc: std.mem.Allocator, argv: [*]const abi.Slice_ABI, argc: usize) !CliRequest {
    const slice_argv = try alloc.alloc([]const u8, argc);
    defer alloc.free(slice_argv);
    for (0..argc) |idx| {
        slice_argv[idx] = argv[idx].toSlice();
    }

    var parsed = try cli_app.parse(alloc, slice_argv);
    defer parsed.deinit();

    if (parsed.action != .run) {
        return .{
            .action = parsed.action,
            .help_command = parsed.help_command,
            .args_json = try alloc.dupe(u8, "{}"),
        };
    }

    const cmd = parsed.primaryCommand() orelse "";
    const is_custom = !isBuiltinCommand(cmd);

    var pipeline_path: []const u8 = parsed.getValue(@tagName(CliOption.pipeline)) orelse "";
    var payload: []const u8 = parsed.getValue(@tagName(CliOption.payload)) orelse "";

    if (!is_custom and pipeline_path.len == 0 and parsed.positionals.items.len > 0) {
        pipeline_path = parsed.positionals.items[0];
    } else if (is_custom and payload.len == 0 and parsed.positionals.items.len > 0) {
        payload = parsed.positionals.items[0];
    }

    const args_json = try parsed.toArgsJson(alloc, is_custom);

    return .{
        .action = .run,
        .route = cmd,
        .pipeline_path = pipeline_path,
        .payload = payload,
        .is_custom = is_custom,
        .args_json = args_json,
    };
}
