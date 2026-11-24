const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const impl = @import("auth_extension.zig");

pub const manifest = impl.manifest;

comptime {
    @export(&manifest, .{ .name = @import("plugin_options").manifest_symbol, .linkage = .strong });
}

test {
    _ = impl;
}
