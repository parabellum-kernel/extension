const std = @import("std");
const Allocator = std.mem.Allocator;
const parabellum = @import("parabellum");
const KernelContext = parabellum.kernel.KernelContext;
const Extension = parabellum.kernel.Extension;
const InboundTransport = parabellum.transport.inbound.InboundTransport;
const InboundTransportConfig = parabellum.transport.inbound.InboundTransportConfig;

pub const grpc_transport = @import("grpc_transport.zig");
pub const GrpcTransport = grpc_transport.GrpcTransport;

pub fn createDaemon(allocator: Allocator, config: InboundTransportConfig) anyerror!InboundTransport {
    return GrpcTransport.createDaemon(allocator, config);
}

pub const extension = Extension.fromStateless("parabellum.inbound.grpc", struct {
    fn reg(k: *KernelContext) anyerror!void {
        try k.inbound.register("grpc", &createDaemon);
    }
}.reg);
