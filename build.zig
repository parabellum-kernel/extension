const std = @import("std");
const sdk_build = @import("parabellum_sdk");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk_dep = b.dependency("parabellum_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const sdk_mod = sdk_dep.module("parabellum_sdk");
    const libs_dep = b.dependency("parabellum_libs", .{
        .target = target,
        .optimize = optimize,
    });
    const platform_mod = libs_dep.module("parabellum_platform");
    const yaml_mod = libs_dep.module("parabellum_yaml");
    const crypto_mod = libs_dep.module("parabellum_crypto");
    const otp_mod = libs_dep.module("otp");
    const mfa_mod = libs_dep.module("parabellum_mfa");

    _ = b.addModule("ext_opentelemetry", .{
        .root_source_file = b.path("opentelemetry/src/opentelemetry.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "parabellum_sdk", .module = sdk_mod },
            .{ .name = "parabellum_platform", .module = platform_mod },
        },
    });
    _ = b.addModule("ext_trace_jsonl", .{
        .root_source_file = b.path("trace_jsonl/src/trace_jsonl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "parabellum_sdk", .module = sdk_mod },
            .{ .name = "parabellum_platform", .module = platform_mod },
        },
    });

    _ = b.addModule("tui_inbound", .{
        .root_source_file = b.path("tui_inbound/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "parabellum_sdk", .module = sdk_mod },
            .{ .name = "parabellum_platform", .module = platform_mod },
        },
    });
    _ = b.addModule("yaml_config", .{
        .root_source_file = b.path("yaml_config/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "parabellum_sdk", .module = sdk_mod },
            .{ .name = "parabellum_platform", .module = platform_mod },
            .{ .name = "parabellum_yaml", .module = yaml_mod },
        },
    });

    const extensions = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "authentication", .path = "authentication/src/plugin.zig" },
        .{ .name = "dag_viz", .path = "dag_viz/src/plugin.zig" },
        .{ .name = "inbound_cli", .path = "inbound_cli/src/plugin.zig" },
        .{ .name = "inbound_fs", .path = "inbound_fs/src/plugin.zig" },
        .{ .name = "inbound_http", .path = "inbound_http/src/plugin.zig" },
        .{ .name = "inbound_grpc", .path = "inbound_grpc/src/plugin.zig" },
        .{ .name = "opentelemetry", .path = "opentelemetry/src/plugin.zig" },
        .{ .name = "pcapng", .path = "pcapng/src/plugin.zig" },
        .{ .name = "trace_jsonl", .path = "trace_jsonl/src/plugin.zig" },
        .{ .name = "tui_inbound", .path = "tui_inbound/src/plugin.zig" },
        .{ .name = "yaml_config", .path = "yaml_config/src/plugin.zig" },
    };

    const test_step = b.step("test", "Run all extension C-ABI conformance tests");
    for (extensions) |ext| {
        const ext_so = sdk_build.addExtensionPlugin(b, sdk_dep, .{
            .name = ext.name,
            .root_source_file = b.path(ext.path),
            .target = target,
            .optimize = optimize,
        });
        ext_so.root_module.addImport("parabellum_platform", platform_mod);
        ext_so.root_module.addImport("parabellum_yaml", yaml_mod);
        ext_so.root_module.addImport("parabellum_crypto", crypto_mod);
        ext_so.root_module.addImport("otp", otp_mod);
        ext_so.root_module.addImport("parabellum_mfa", mfa_mod);
        b.installArtifact(ext_so);
        const ext_a = b.addLibrary(.{
            .linkage = .static,
            .name = ext_so.name,
            .root_module = ext_so.root_module,
        });
        ext_a.bundle_compiler_rt = false;
        b.installArtifact(ext_a);
        const run_t = b.addRunArtifact(b.addTest(.{ .root_module = ext_so.root_module }));
        test_step.dependOn(&run_t.step);
    }
}

