const std = @import("std");
const sdk_build = @import("parabellum_sdk");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk_dep = b.dependency("parabellum_sdk", .{
        .target = target,
        .optimize = optimize,
    });

    const extensions = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "artifact", .path = "artifact/src/plugin.zig" },
        .{ .name = "dag_viz", .path = "dag_viz/src/plugin.zig" },
        .{ .name = "inbound_cli", .path = "inbound_cli/src/plugin.zig" },
        .{ .name = "inbound_http", .path = "inbound_http/src/plugin.zig" },
        .{ .name = "inbound_grpc", .path = "inbound_grpc/src/plugin.zig" },
        .{ .name = "opentelemetry", .path = "opentelemetry/src/plugin.zig" },
        .{ .name = "pcapng", .path = "pcapng/src/plugin.zig" },
        .{ .name = "trace_jsonl", .path = "trace_jsonl/src/plugin.zig" },
    };

    const test_step = b.step("test", "Run all extension C-ABI conformance tests");
    for (extensions) |ext| {
        const ext_so = sdk_build.addExtensionPlugin(b, sdk_dep, .{
            .name = ext.name,
            .root_source_file = b.path(ext.path),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(ext_so);
        const run_t = b.addRunArtifact(b.addTest(.{ .root_module = ext_so.root_module }));
        test_step.dependOn(&run_t.step);
    }
}

