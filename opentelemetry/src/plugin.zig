const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const impl = @import("opentelemetry.zig");

pub const manifest = impl.manifest;

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test {
    _ = impl;
}
