const std = @import("std");
const Allocator = std.mem.Allocator;
const parabellum = @import("parabellum");
const KernelContext = parabellum.kernel.KernelContext;
const Extension = parabellum.kernel.Extension;
const InboundTransport = parabellum.transport.inbound.InboundTransport;
const InboundTransportConfig = parabellum.transport.inbound.InboundTransportConfig;

pub const cli_transport = @import("cli_transport.zig");
pub const CliTransport = cli_transport.CliTransport;

pub fn createDaemon(allocator: Allocator, config: InboundTransportConfig) anyerror!InboundTransport {
    const s = try allocator.create(CliTransport);
    s.* = CliTransport.init(allocator, config.args);
    s.is_heap_allocated = true;
    return s.inboundTransport();
}

pub const extension = Extension.fromStateless("parabellum.inbound.cli", struct {
    fn reg(k: *KernelContext) anyerror!void {
        try k.inbound.register("cli", &createDaemon);
    }
}.reg);
