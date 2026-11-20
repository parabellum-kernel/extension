const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("parabellum_sdk");
const cap = sdk.capabilities;

pub const ParsedCapabilityCall = struct {
    capability: cap.CapabilitySpec,
    payload_json: []u8,

    pub fn deinit(self: *ParsedCapabilityCall, alloc: Allocator) void {
        alloc.free(self.payload_json);
    }
};

/// Formats subcommands and flags grouped by `CapabilitySpec.group` for `--help`.
pub fn formatCatalogHelp(alloc: Allocator, catalog: cap.CapabilityCatalog) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print("{s} ({s})\n\nCapabilities:\n", .{ catalog.name, catalog.version });
    for (catalog.capabilities) |spec| {
        const title = spec.title orelse spec.id;
        try w.print("  {s} {s}", .{ spec.group, spec.id });
        for (spec.inputs) |inp| {
            if (inp.required) {
                try w.print(" --{s} <{s}>", .{ inp.name, @tagName(inp.field_type) });
            } else {
                try w.print(" [--{s} <{s}>]", .{ inp.name, @tagName(inp.field_type) });
            }
        }
        try w.print("  - {s}\n", .{title});
    }
    return try aw.toOwnedSlice();
}

/// Attempts to match `argv` (`<group> <id> [--<field> <val>...]`) against `catalog`.
/// Returns `null` if `argv` does not match a declared capability.
pub fn tryParseCapabilityArgs(
    alloc: Allocator,
    catalog: cap.CapabilityCatalog,
    argv: []const []const u8,
) !?ParsedCapabilityCall {
    if (argv.len < 2) return null;
    const grp = argv[0];
    const cap_id = argv[1];

    const spec = blk: {
        for (catalog.capabilities) |c| {
            if (std.mem.eql(u8, c.group, grp) and std.mem.eql(u8, c.id, cap_id)) {
                break :blk c;
            }
        }
        return null;
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('{');

    var first = true;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        const key = arg[2..];
        const val: []const u8 = if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "--")) blk: {
            i += 1;
            break :blk argv[i];
        } else "true";

        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\":\"{s}\"", .{ key, val });
    }
    try w.writeByte('}');

    return .{
        .capability = spec,
        .payload_json = try aw.toOwnedSlice(),
    };
}

test "ir_cli formats capability help and parses --flag arguments into JSON" {
    const alloc = std.testing.allocator;
    const catalog = cap.CapabilityCatalog{
        .id = "vault",
        .name = "Vault",
        .version = "0.2.0",
        .capabilities = &.{
            .{
                .id = "ls",
                .group = "vfs",
                .title = "List directory",
                .inputs = &.{
                    .{ .name = "path", .field_type = .dir_path, .required = false },
                },
            },
        },
    };

    const help = try formatCatalogHelp(alloc, catalog);
    defer alloc.free(help);
    try std.testing.expect(std.mem.indexOf(u8, help, "vfs ls [--path <dir_path>]") != null);

    var parsed = (try tryParseCapabilityArgs(alloc, catalog, &.{ "vfs", "ls", "--path", "/docs" })).?;
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("ls", parsed.capability.id);
    try std.testing.expectEqualStrings("{\"path\":\"/docs\"}", parsed.payload_json);
}
