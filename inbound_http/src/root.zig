const std = @import("std");
const Allocator = std.mem.Allocator;
const parabellum = @import("parabellum");
const KernelContext = parabellum.kernel.KernelContext;
const Extension = parabellum.kernel.Extension;
const InboundTransport = parabellum.transport.inbound.InboundTransport;
const InboundTransportConfig = parabellum.transport.inbound.InboundTransportConfig;

pub const http_transport = @import("http_transport.zig");
pub const HttpServerTransport = http_transport.HttpServerTransport;
pub const HttpTransport = HttpServerTransport;

pub fn createDaemon(allocator: Allocator, config: InboundTransportConfig) anyerror!InboundTransport {
    return HttpServerTransport.createDaemon(allocator, config);
}

pub const extension = Extension.fromStateless("parabellum.inbound.http", struct {
    fn reg(k: *KernelContext) anyerror!void {
        try k.inbound.register("http", &createDaemon);
    }
}.reg);
