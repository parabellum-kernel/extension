const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const cap = sdk.capabilities;

pub const BufferedSseEvent = struct {
    topic: [64]u8 = undefined,
    topic_len: usize = 0,
    data: [1024]u8 = undefined,
    data_len: usize = 0,

    pub fn topicSlice(self: *const BufferedSseEvent) []const u8 {
        return self.topic[0..self.topic_len];
    }

    pub fn dataSlice(self: *const BufferedSseEvent) []const u8 {
        return self.data[0..self.data_len];
    }
};

/// Bounded non-blocking event ring buffer for `http_inbound` SSE (`GET /events`).
/// Drops oldest events on overflow so slow HTTP clients never stall kernel workers.
pub const EventRing = struct {
    pub const CAPACITY: usize = 64;

    slots: [CAPACITY]BufferedSseEvent = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    dropped: u64 = 0,
    mutex: std.Io.Mutex = .init,

    fn topicForKind(kind: abi.TelemetryEventKind_ABI, primary: []const u8) []const u8 {
        return switch (kind) {
            .job_started => "job.started",
            .job_progress => if (primary.len > 0) primary else "job.progress",
            .job_completed => "job.completed",
            .job_failed => "job.failed",
            .artifact_ready => if (primary.len > 0) primary else "ui.artifact_ready",
            .vfs_changed => "ui.vfs_changed",
            .input_required => "ui.input_required",
            else => "trace.telemetry",
        };
    }

    pub fn pushAbiEvent(self: *EventRing, ev: *const abi.TelemetryEvent_ABI) void {
        const topic = topicForKind(ev.kind, ev.primary_name.toSlice());
        var entry = BufferedSseEvent{};
        const tlen = @min(topic.len, entry.topic.len);
        @memcpy(entry.topic[0..tlen], topic[0..tlen]);
        entry.topic_len = tlen;

        const msg_slice = ev.payload.toSlice();
        const json_slice = std.fmt.bufPrint(
            &entry.data,
            "{{\"kind\":\"{s}\",\"topic\":\"{s}\",\"count_a\":{d},\"count_b\":{d},\"payload_len\":{d}}}",
            .{ @tagName(ev.kind), topic[0..tlen], ev.count_a, ev.count_b, msg_slice.len },
        ) catch "{\"kind\":\"unknown\"}";
        entry.data_len = json_slice.len;

        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        if (self.count == CAPACITY) {
            self.head = (self.head + 1) % CAPACITY;
            self.count -= 1;
            self.dropped += 1;
        }
        self.slots[self.tail] = entry;
        self.tail = (self.tail + 1) % CAPACITY;
        self.count += 1;
    }

    fn matchesTopics(topic: []const u8, filter: []const u8) bool {
        if (filter.len == 0) {
            return std.mem.startsWith(u8, topic, "job.") or std.mem.startsWith(u8, topic, "ui.");
        }
        var it = std.mem.splitScalar(u8, filter, ',');
        while (it.next()) |pat| {
            const p = std.mem.trim(u8, pat, " \t");
            if (p.len == 0) continue;
            if (std.mem.endsWith(u8, p, "*")) {
                if (std.mem.startsWith(u8, topic, p[0 .. p.len - 1])) return true;
            } else if (std.mem.eql(u8, topic, p)) {
                return true;
            }
        }
        return false;
    }

    /// Drains matching events formatted as an SSE stream (`text/event-stream`).
    pub fn drainSse(self: *EventRing, alloc: Allocator, topics_filter: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();

        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        while (self.count > 0) {
            const item = self.slots[self.head];
            self.head = (self.head + 1) % CAPACITY;
            self.count -= 1;

            const topic = item.topicSlice();
            if (!matchesTopics(topic, topics_filter)) continue;
            try aw.writer.print("event: {s}\ndata: {s}\n\n", .{ topic, item.dataSlice() });
        }
        return try aw.toOwnedSlice();
    }
};

/// Resolves `/api/<group>/<id>` to the matching `CapabilitySpec` in `catalog`.
pub fn matchCapabilityRoute(catalog: cap.CapabilityCatalog, path: []const u8) ?cap.CapabilitySpec {
    if (!std.mem.startsWith(u8, path, "/api/")) return null;
    const rest = path["/api/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const grp = rest[0..slash];
    const cap_id = rest[slash + 1 ..];
    for (catalog.capabilities) |spec| {
        if (std.mem.eql(u8, spec.group, grp) and std.mem.eql(u8, spec.id, cap_id)) {
            return spec;
        }
    }
    return null;
}

/// Generates an OpenAPI 3.1 JSON document derived from `CapabilityCatalog`.
pub fn buildOpenApiJson(alloc: Allocator, catalog: cap.CapabilityCatalog) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        "{{\"openapi\":\"3.1.0\",\"info\":{{\"title\":\"{s}\",\"version\":\"{s}\"}},\"paths\":{{",
        .{ catalog.name, catalog.version },
    );

    for (catalog.capabilities, 0..) |spec, idx| {
        if (idx > 0) try w.writeByte(',');
        var method_lower: []const u8 = if (spec.execution_mode == .sync_fast) "get" else "post";
        for (spec.hints) |h| {
            if (std.mem.eql(u8, h.key, "http.method")) {
                if (std.ascii.eqlIgnoreCase(h.value, "GET")) method_lower = "get" else method_lower = "post";
            }
        }
        const status_code: []const u8 = if (spec.execution_mode == .async_job) "202" else "200";
        const desc = spec.description orelse (spec.title orelse spec.id);

        try w.print(
            "\"/api/{s}/{s}\":{{\"{s}\":{{\"summary\":\"{s}\",\"operationId\":\"{s}\",\"responses\":{{\"{s}\":{{\"description\":\"OK\"}}}}}}}}",
            .{ spec.group, spec.id, method_lower, desc, spec.id, status_code },
        );
    }

    try w.writeAll("}}");
    return try aw.toOwnedSlice();
}

test "capability_router matches routes, builds OpenAPI 3.1 JSON and formats SSE" {
    const alloc = std.testing.allocator;
    const catalog = cap.CapabilityCatalog{
        .id = "vault",
        .name = "Vault",
        .version = "0.2.0",
        .capabilities = &.{
            .{
                .id = "vfs.list",
                .group = "vfs",
                .title = "List VFS",
                .execution_mode = .sync_fast,
            },
        },
    };

    const matched = matchCapabilityRoute(catalog, "/api/vfs/vfs.list").?;
    try std.testing.expectEqualStrings("vfs.list", matched.id);
    try std.testing.expect(matchCapabilityRoute(catalog, "/api/vfs/unknown") == null);

    const openapi = try buildOpenApiJson(alloc, catalog);
    defer alloc.free(openapi);
    try std.testing.expect(std.mem.indexOf(u8, openapi, "\"openapi\":\"3.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi, "\"/api/vfs/vfs.list\"") != null);

    var ring = EventRing{};
    var ev = std.mem.zeroes(abi.TelemetryEvent_ABI);
    ev.kind = .job_progress;
    ev.primary_name = abi.Slice_ABI.from("job.progress");
    ev.count_a = 1;
    ev.count_b = 50;
    ring.pushAbiEvent(&ev);

    const sse = try ring.drainSse(alloc, "");
    defer alloc.free(sse);
    try std.testing.expect(std.mem.indexOf(u8, sse, "event: job.progress\n") != null);
}
