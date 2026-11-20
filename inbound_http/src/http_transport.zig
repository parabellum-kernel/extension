//! Self-contained HTTP/1.1 inbound server (depends only on `std` + libc).
//! The host dispatcher is abstracted behind `Dispatch`, so this file has no knowledge of the engine.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = std.c;
const sdk = @import("parabellum_sdk");
const cap_router = @import("capability_router.zig");

/// Which kind of payload `Request.payload` carries (mapped to the host's `InputSource`).
pub const InputKind = enum { none, memory_bytes, job_json };

pub const Request = struct {
    /// "health" | "version" | "validate" | "run" | custom command name.
    route: []const u8,
    is_custom: bool = false,
    pipeline_path: []const u8 = "",
    payload: []const u8 = "",
    input_kind: InputKind = .none,
    load_shared_modules: bool = true,
};

pub const Response = struct {
    status_code: u16 = 200,
    ok: bool,
    /// Owned by the dispatcher; only valid until the next dispatch call.
    body: []const u8,
};

pub const Dispatch = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, req: Request) anyerror!Response,

    fn call(self: Dispatch, req: Request) anyerror!Response {
        return self.func(self.ctx, req);
    }
};

pub const Config = struct {
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 8080,
    default_pipeline_path: []const u8 = "",
    read_timeout_ms: u32 = 30_000,
    auth_token: []const u8 = "",
    catalog: ?sdk.capabilities.CapabilityCatalog = null,
    event_ring: ?*cap_router.EventRing = null,
};

/// Parses `host:port`, `:port` or `port` into a `Config` (slices borrow from `listen_address`).
pub fn parseListenAddress(listen_address: []const u8, pipeline_path: []const u8) Config {
    var cfg = Config{ .default_pipeline_path = pipeline_path };
    if (std.mem.lastIndexOfScalar(u8, listen_address, ':')) |colon| {
        if (colon > 0) cfg.listen_host = listen_address[0..colon];
        cfg.listen_port = std.fmt.parseInt(u16, listen_address[colon + 1 ..], 10) catch 8080;
    } else if (std.fmt.parseInt(u16, listen_address, 10) catch null) |p| {
        cfg.listen_port = p;
    } else if (listen_address.len > 0) {
        cfg.listen_host = listen_address;
    }
    return cfg;
}

/// Returns an IPv4 address in network byte order.
fn parseIpv4(host: []const u8) !u32 {
    if (std.mem.eql(u8, host, "localhost")) return std.mem.nativeToBig(u32, 0x7F000001);
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidListenHost;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidListenHost;
    }
    if (i != 4) return error.InvalidListenHost;
    return @bitCast(octets); // bytes already in network order
}

pub fn formatHttpResponse(
    allocator: Allocator,
    status_code: u16,
    reason: []const u8,
    body: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ status_code, reason, body.len, body },
    );
}

fn formatStreamResponse(
    allocator: Allocator,
    status_code: u16,
    reason: []const u8,
    content_type: []const u8,
    content_range: []const u8,
    content_len: usize,
    raw_bytes: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: {d}\r\n",
        .{ status_code, reason, content_type, content_len },
    );
    if (content_range.len > 0) {
        try aw.writer.print("Content-Range: {s}\r\n", .{content_range});
    }
    try aw.writer.writeAll("Connection: close\r\n\r\n");
    if (raw_bytes.len > 0) {
        try aw.writer.writeAll(raw_bytes);
    }
    return try aw.toOwnedSlice();
}

/// Extracts the inner job payload bytes from a `JobEnvelope` JSON body.
/// Supports `payload_raw` (ARCH-019) and `payload`, as a JSON string or embedded object/array.
fn extractJobEnvelopePayload(allocator: Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJobEnvelope;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJobEnvelope;

    const payload_val = parsed.value.object.get("payload_raw") orelse
        parsed.value.object.get("payload") orelse
        return try allocator.dupe(u8, body);

    return switch (payload_val) {
        .string => |s| try allocator.dupe(u8, s),
        .object, .array => try std.json.Stringify.valueAlloc(allocator, payload_val, .{}),
        else => error.InvalidJobPayload,
    };
}

pub const HttpServer = struct {
    allocator: Allocator,
    config: Config,

    pub fn init(allocator: Allocator, config: Config) HttpServer {
        return .{ .allocator = allocator, .config = config };
    }

    /// Processes a raw HTTP/1.x request buffer and returns a complete HTTP/1.x response (caller frees).
    pub fn handleHttpRequest(self: *HttpServer, raw_request: []const u8, dispatch: Dispatch) ![]u8 {
        const allocator = self.allocator;
        if (raw_request.len < 10) {
            return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"malformed_request\"}\n");
        }

        const header_end = std.mem.indexOf(u8, raw_request, "\r\n\r\n") orelse raw_request.len;
        const headers_part = raw_request[0..header_end];
        const body = if (header_end + 4 <= raw_request.len) raw_request[header_end + 4 ..] else "";

        const first_line_end = std.mem.indexOf(u8, headers_part, "\r\n") orelse headers_part.len;
        var line_tok = std.mem.tokenizeScalar(u8, headers_part[0..first_line_end], ' ');
        const method = line_tok.next() orelse return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"missing_method\"}\n");
        const path = line_tok.next() orelse "/";

        var custom_pipe_path: ?[]const u8 = null;
        var skip_so = false;
        var hdr_range: []const u8 = "";
        var hdr_auth: []const u8 = "";

        var line_it = std.mem.splitSequence(u8, headers_part, "\r\n");
        _ = line_it.next();
        while (line_it.next()) |hdr| {
            const colon = std.mem.indexOfScalar(u8, hdr, ':') orelse continue;
            const h_name = std.mem.trim(u8, hdr[0..colon], " \t");
            const h_val = std.mem.trim(u8, hdr[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(h_name, "x-pipeline-path")) {
                custom_pipe_path = h_val;
            } else if (std.ascii.eqlIgnoreCase(h_name, "x-skip-so")) {
                skip_so = std.ascii.eqlIgnoreCase(h_val, "true") or std.mem.eql(u8, h_val, "1");
            } else if (std.ascii.eqlIgnoreCase(h_name, "range")) {
                hdr_range = h_val;
            } else if (std.ascii.eqlIgnoreCase(h_name, "authorization")) {
                hdr_auth = h_val;
            }
        }
        const pipeline = custom_pipe_path orelse self.config.default_pipeline_path;
        const is_get = std.mem.eql(u8, method, "GET");
        const is_head = std.mem.eql(u8, method, "HEAD");
        const is_post = std.mem.eql(u8, method, "POST");

        if (self.config.auth_token.len > 0 and (std.mem.startsWith(u8, path, "/api/") or std.mem.startsWith(u8, path, "/events"))) {
            const expected_prefix = "Bearer ";
            const ok_auth = std.mem.startsWith(u8, hdr_auth, expected_prefix) and
                std.mem.eql(u8, hdr_auth[expected_prefix.len..], self.config.auth_token);
            if (!ok_auth) {
                return formatHttpResponse(allocator, 401, "Unauthorized", "{\"error\":\"unauthorized\"}\n");
            }
        }

        if (is_get and std.mem.eql(u8, path, "/capabilities")) {
            if (self.config.catalog) |cat| {
                const cat_json = try sdk.capabilities.toJson(allocator, cat);
                defer allocator.free(cat_json);
                return formatHttpResponse(allocator, 200, "OK", cat_json);
            }
            return formatHttpResponse(allocator, 200, "OK", "{\"id\":\"\",\"name\":\"\",\"capabilities\":[]}\n");
        }

        if (is_get and std.mem.eql(u8, path, "/openapi.json")) {
            if (self.config.catalog) |cat| {
                const oa_json = try cap_router.buildOpenApiJson(allocator, cat);
                defer allocator.free(oa_json);
                return formatHttpResponse(allocator, 200, "OK", oa_json);
            }
            return formatHttpResponse(allocator, 200, "OK", "{\"openapi\":\"3.1.0\",\"paths\":{}}\n");
        }

        if (is_get and (std.mem.eql(u8, path, "/events") or std.mem.startsWith(u8, path, "/events?"))) {
            var topics: []const u8 = "";
            if (std.mem.indexOf(u8, path, "topics=")) |ti| {
                const rest = path[ti + "topics=".len ..];
                topics = if (std.mem.indexOfScalar(u8, rest, '&')) |amp| rest[0..amp] else rest;
            }
            const sse_body = if (self.config.event_ring) |ring|
                try ring.drainSse(allocator, topics)
            else
                try allocator.dupe(u8, "");
            defer allocator.free(sse_body);
            return std.fmt.allocPrint(
                allocator,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ sse_body.len, sse_body },
            );
        }

        if ((is_get or is_post) and std.mem.startsWith(u8, path, "/api/")) {
            if (self.config.catalog) |cat| {
                const clean_path = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[0..q] else path;
                if (cap_router.matchCapabilityRoute(cat, clean_path)) |cap_spec| {
                    const r = try dispatch.call(.{
                        .route = cap_spec.id,
                        .is_custom = true,
                        .pipeline_path = pipeline,
                        .payload = body,
                        .input_kind = if (body.len > 0) .job_json else .none,
                    });
                    const code: u16 = if (r.ok and cap_spec.execution_mode == .async_job) 202 else r.status_code;
                    const reason: []const u8 = if (code == 202) "Accepted" else if (r.ok) "OK" else "Bad Request";
                    return formatHttpResponse(allocator, code, reason, r.body);
                }
            }
            return formatHttpResponse(allocator, 404, "Not Found", "{\"error\":\"unknown_capability\"}\n");
        }

        if (is_get and (std.mem.eql(u8, path, "/v1/health") or std.mem.eql(u8, path, "/health"))) {
            const r = try dispatch.call(.{ .route = "health", .pipeline_path = pipeline });
            return formatHttpResponse(allocator, 200, "OK", r.body);
        }
        if (is_get and (std.mem.eql(u8, path, "/v1/version") or std.mem.eql(u8, path, "/version"))) {
            const r = try dispatch.call(.{ .route = "version", .pipeline_path = pipeline });
            return formatHttpResponse(allocator, 200, "OK", r.body);
        }

        if (is_post and std.mem.startsWith(u8, path, "/v1/validate")) {
            if (pipeline.len == 0) return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"missing_pipeline_path\"}\n");
            const r = try dispatch.call(.{ .route = "validate", .pipeline_path = pipeline, .load_shared_modules = !skip_so });
            return formatHttpResponse(allocator, if (r.ok) 200 else 400, if (r.ok) "OK" else "Validation Error", r.body);
        }

        if (is_post and std.mem.startsWith(u8, path, "/v1/run")) {
            if (pipeline.len == 0) return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"missing_pipeline_path\"}\n");
            const r = try dispatch.call(.{
                .route = "run",
                .pipeline_path = pipeline,
                .payload = body,
                .input_kind = if (body.len > 0) .memory_bytes else .none,
                .load_shared_modules = !skip_so,
            });
            return formatHttpResponse(allocator, if (r.ok) 200 else 500, if (r.ok) "OK" else "Execution Failed", r.body);
        }

        if ((is_get or is_head) and std.mem.startsWith(u8, path, "/stream/")) {
            if (pipeline.len == 0) return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"missing_pipeline_path\"}\n");
            const raw_tail = path["/stream/".len..];
            const no_query = if (std.mem.indexOfScalar(u8, raw_tail, '?')) |q| raw_tail[0..q] else raw_tail;
            const slash = std.mem.indexOfScalar(u8, no_query, '/');
            const inode_id = if (slash) |si| no_query[0..si] else no_query;
            if (inode_id.len == 0) return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"missing_inode_id\"}\n");

            const max_chunk_str: []const u8 = if (is_head) "1" else "1048576";
            const job_json = try std.fmt.allocPrint(
                allocator,
                "{{\"pipeline\":\"read\",\"op\":\"stream\",\"encoding\":\"base64\",\"inode_id\":\"{s}\",\"range\":\"{s}\",\"max_len\":{s}}}",
                .{ inode_id, hdr_range, max_chunk_str },
            );
            defer allocator.free(job_json);

            const r = try dispatch.call(.{
                .route = "run",
                .pipeline_path = pipeline,
                .payload = job_json,
                .input_kind = .job_json,
                .load_shared_modules = !skip_so,
            });
            if (!r.ok) return formatHttpResponse(allocator, 404, "Not Found", r.body);

            const parsed = std.json.parseFromSlice(struct {
                output: ?struct {
                    status_code: i64 = 200,
                    total_size: i64 = 0,
                    content_range: []const u8 = "",
                    mime_type: []const u8 = "application/octet-stream",
                    data: []const u8 = "",
                } = null,
            }, allocator, r.body, .{ .ignore_unknown_fields = true }) catch {
                return formatHttpResponse(allocator, 500, "Internal Server Error", r.body);
            };
            defer parsed.deinit();

            const out = parsed.value.output orelse return formatHttpResponse(allocator, 404, "Not Found", "{\"error\":\"empty_stream_output\"}\n");
            const content_type = if (out.mime_type.len > 0) out.mime_type else "application/octet-stream";
            if (is_head) {
                const total_u: usize = @intCast(@max(0, out.total_size));
                return formatStreamResponse(allocator, 200, "OK", content_type, "", total_u, &.{});
            }

            const max_len = try std.base64.standard.Decoder.calcSizeUpperBound(out.data.len);
            const raw_buf = try allocator.alloc(u8, max_len);
            defer allocator.free(raw_buf);
            try std.base64.standard.Decoder.decode(raw_buf, out.data);
            const exact_len = std.base64.standard.Decoder.calcSizeForSlice(out.data) catch max_len;
            const raw_bytes = raw_buf[0..exact_len];

            const code: u16 = if (out.status_code == 206) 206 else 200;
            const reason: []const u8 = if (code == 206) "Partial Content" else "OK";
            return formatStreamResponse(allocator, code, reason, content_type, out.content_range, raw_bytes.len, raw_bytes);
        }

        if (is_get and std.mem.eql(u8, path, "/v1/jobs")) {
            const r = try dispatch.call(.{
                .route = "jobs",
                .is_custom = true,
                .pipeline_path = pipeline,
            });
            return formatHttpResponse(allocator, if (r.ok) 200 else 500, if (r.ok) "OK" else "Error", r.body);
        }

        if (is_post and (std.mem.eql(u8, path, "/v1/jobs") or std.mem.startsWith(u8, path, "/v1/jobs?"))) {
            if (pipeline.len == 0) return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"missing_pipeline_path\"}\n");
            if (body.len == 0) return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"empty_job_envelope\"}\n");

            const payload_bytes = extractJobEnvelopePayload(allocator, body) catch |err| {
                const err_json = switch (err) {
                    error.InvalidJobPayload => "{\"error\":\"invalid_job_payload\"}\n",
                    else => "{\"error\":\"invalid_job_envelope\"}\n",
                };
                return formatHttpResponse(allocator, 400, "Bad Request", err_json);
            };
            defer allocator.free(payload_bytes);

            const r = try dispatch.call(.{
                .route = "run",
                .pipeline_path = pipeline,
                .payload = payload_bytes,
                .input_kind = .job_json,
                .load_shared_modules = !skip_so,
            });
            return formatHttpResponse(allocator, if (r.ok) 200 else 500, if (r.ok) "OK" else "Execution Failed", r.body);
        }

        if (std.mem.startsWith(u8, path, "/v1/custom/")) {
            const r = try dispatch.call(.{
                .route = path["/v1/custom/".len..],
                .is_custom = true,
                .pipeline_path = pipeline,
                .payload = body,
                .input_kind = if (body.len > 0) .memory_bytes else .none,
            });
            const status_text = if (r.status_code == 200)
                "OK"
            else if (r.status_code == 404)
                "Not Found"
            else
                "Internal Server Error";
            return formatHttpResponse(allocator, r.status_code, status_text, r.body);
        }

        return formatHttpResponse(allocator, 404, "Not Found", "{\"error\":\"not_found\"}\n");
    }

    /// Blocking accept loop on a POSIX TCP socket. Only returns on setup failure.
    pub fn serveLoop(self: *HttpServer, dispatch: Dispatch) anyerror!void {
        const sock_fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (sock_fd < 0) return error.SocketCreateFailed;
        defer _ = c.close(sock_fd);

        var opt: c_int = 1;
        _ = c.setsockopt(sock_fd, c.SOL.SOCKET, c.SO.REUSEADDR, &opt, @sizeOf(c_int));

        var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
        addr.family = c.AF.INET;
        addr.port = std.mem.nativeToBig(u16, self.config.listen_port);
        addr.addr = try parseIpv4(self.config.listen_host);

        if (c.bind(sock_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.BindFailed;
        if (c.listen(sock_fd, 64) != 0) return error.ListenFailed;

        const MAX_BODY_SIZE = 128 * 1024 * 1024; // 128 MiB
        var recv_chunk: [65536]u8 = undefined;

        while (true) {
            const client_fd = c.accept(sock_fd, null, null);
            if (client_fd < 0) continue;
            defer _ = c.close(client_fd);

            var tv: c.timeval = .{
                .sec = @intCast(self.config.read_timeout_ms / 1000),
                .usec = @intCast((self.config.read_timeout_ms % 1000) * 1000),
            };
            _ = c.setsockopt(client_fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &tv, @sizeOf(c.timeval));

            var req_accum = std.ArrayListUnmanaged(u8).empty;
            defer req_accum.deinit(self.allocator);

            var content_length: ?usize = null;
            var header_end_idx: ?usize = null;

            while (true) {
                const n = c.recv(client_fd, &recv_chunk, recv_chunk.len, 0);
                if (n <= 0) break;
                req_accum.appendSlice(self.allocator, recv_chunk[0..@intCast(n)]) catch break;

                // Check if headers have finished
                if (header_end_idx == null) {
                    if (std.mem.indexOf(u8, req_accum.items, "\r\n\r\n")) |h_end| {
                        header_end_idx = h_end + 4;
                        const headers_slice = req_accum.items[0..h_end];
                        var line_it = std.mem.splitSequence(u8, headers_slice, "\r\n");
                        while (line_it.next()) |line| {
                            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                                const val_str = std.mem.trim(u8, line["content-length:".len..], " \t");
                                content_length = std.fmt.parseInt(usize, val_str, 10) catch 0;
                                break;
                            }
                        }
                    }
                }

                if (header_end_idx) |h_len| {
                    const clen = content_length orelse 0;
                    if (clen > MAX_BODY_SIZE) break;
                    if (req_accum.items.len >= h_len + clen) {
                        break;
                    }
                }
            }

            if (req_accum.items.len == 0) continue;

            const resp_bytes = self.handleHttpRequest(req_accum.items, dispatch) catch
                try formatHttpResponse(self.allocator, 500, "Internal Server Error", "{\"error\":\"internal_error\"}\n");
            defer self.allocator.free(resp_bytes);

            _ = c.send(client_fd, resp_bytes.ptr, resp_bytes.len, 0);
        }
    }
};

const TestDispatch = struct {
    fn run(_: *anyopaque, req: Request) anyerror!Response {
        return .{ .ok = true, .body = req.route };
    }
};

test "handleHttpRequest routes health and 404" {
    var dummy: u8 = 0;
    const dispatch = Dispatch{ .ctx = &dummy, .func = TestDispatch.run };
    var server = HttpServer.init(std.testing.allocator, .{});

    const ok = try server.handleHttpRequest("GET /health HTTP/1.1\r\n\r\n", dispatch);
    defer std.testing.allocator.free(ok);
    try std.testing.expect(std.mem.startsWith(u8, ok, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.endsWith(u8, ok, "health"));

    const nf = try server.handleHttpRequest("GET /nope HTTP/1.1\r\n\r\n", dispatch);
    defer std.testing.allocator.free(nf);
    try std.testing.expect(std.mem.startsWith(u8, nf, "HTTP/1.1 404"));
}

test "parseListenAddress" {
    const a = parseListenAddress("127.0.0.1:8787", "p.yaml");
    try std.testing.expectEqualStrings("127.0.0.1", a.listen_host);
    try std.testing.expectEqual(@as(u16, 8787), a.listen_port);
    try std.testing.expectEqual(@as(u16, 9000), parseListenAddress("9000", "").listen_port);
}
