const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const impl = @import("trace_jsonl.zig");

pub const manifest = impl.manifest;

comptime {
    @export(&manifest, .{ .name = @import("plugin_options").manifest_symbol, .linkage = .strong });
}

test {
    _ = impl;
}
