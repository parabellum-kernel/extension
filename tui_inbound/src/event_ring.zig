const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const vtables = sdk.transport.inbound.vtables;

pub const LogEntry = struct {
    kind: abi.TelemetryEventKind_ABI = .task_log,
    trace_id: [16]u8 = @splat(0),
    timestamp_ns: u64 = 0,
    duration_ns: u64 = 0,
    count_a: u64 = 0,
    count_b: u64 = 0,
    flags: u32 = 0,
    primary: [64]u8 = undefined,
    primary_len: usize = 0,
    secondary: [64]u8 = undefined,
    secondary_len: usize = 0,
    payload: [256]u8 = undefined,
    payload_len: usize = 0,

    pub fn primarySlice(self: *const LogEntry) []const u8 {
        return self.primary[0..self.primary_len];
    }

    pub fn secondarySlice(self: *const LogEntry) []const u8 {
        return self.secondary[0..self.secondary_len];
    }

    pub fn payloadSlice(self: *const LogEntry) []const u8 {
        return self.payload[0..self.payload_len];
    }

    pub fn isJobOrUi(self: *const LogEntry) bool {
        return switch (self.kind) {
            .job_started,
            .job_progress,
            .job_completed,
            .job_failed,
            .artifact_ready,
            .vfs_changed,
            .input_required,
            .task_log,
            => true,
            else => false,
        };
    }

    pub fn formatLine(self: *const LogEntry, buf: []u8) []const u8 {
        const tag = @tagName(self.kind);
        const p = self.primarySlice();
        const msg = self.payloadSlice();
        if (p.len > 0 and msg.len > 0) {
            return std.fmt.bufPrint(buf, "[{s}] {s}: {s}", .{ tag, p, msg }) catch buf[0..0];
        } else if (p.len > 0) {
            return std.fmt.bufPrint(buf, "[{s}] {s} ({d}/{d})", .{ tag, p, self.count_a, self.count_b }) catch buf[0..0];
        } else if (msg.len > 0) {
            return std.fmt.bufPrint(buf, "[{s}] {s}", .{ tag, msg }) catch buf[0..0];
        }
        return std.fmt.bufPrint(buf, "[{s}]", .{tag}) catch buf[0..0];
    }
};

/// Bounded non-blocking event ring buffer for `tui_inbound`.
/// Drops oldest events on overflow so kernel workers never block on UI rendering.
pub const EventRing = struct {
    pub const CAPACITY: usize = 256;

    slots: [CAPACITY]LogEntry = undefined,
    head: usize = 0,
    count: usize = 0,
    total_pushed: u64 = 0,
    dropped: u64 = 0,
    mutex: std.Io.Mutex = .init,
    filter: ?vtables.EventFilterVTable = null,
    wakeup_fd: ?std.c.fd_t = null,

    pub fn pushAbiEvent(self: *EventRing, ev: *const abi.TelemetryEvent_ABI) void {
        if (self.filter) |flt| {
            if (!flt.accept(flt.ctx, ev)) return;
        }

        var entry = LogEntry{
            .kind = ev.kind,
            .trace_id = ev.trace_id,
            .timestamp_ns = ev.timestamp_ns,
            .duration_ns = ev.duration_ns,
            .count_a = ev.count_a,
            .count_b = ev.count_b,
            .flags = ev.flags,
        };

        const p = ev.primary_name.toSlice();
        const plen = @min(p.len, entry.primary.len);
        @memcpy(entry.primary[0..plen], p[0..plen]);
        entry.primary_len = plen;

        const s = ev.secondary_name.toSlice();
        const slen = @min(s.len, entry.secondary.len);
        @memcpy(entry.secondary[0..slen], s[0..slen]);
        entry.secondary_len = slen;

        const msg = ev.payload.toSlice();
        const mlen = @min(msg.len, entry.payload.len);
        @memcpy(entry.payload[0..mlen], msg[0..mlen]);
        entry.payload_len = mlen;

        {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            if (self.count == CAPACITY) {
                self.head = (self.head + 1) % CAPACITY;
                self.count -= 1;
                self.dropped += 1;
            }
            const idx = (self.head + self.count) % CAPACITY;
            self.slots[idx] = entry;
            self.count += 1;
            self.total_pushed += 1;
        }

        if (self.wakeup_fd) |fd| {
            const byte = [1]u8{1};
            _ = std.c.write(fd, &byte, 1);
        }
    }

    /// Copies up to `out.len` most recent entries in chronological order (oldest -> newest).
    pub fn snapshotRecent(self: *EventRing, out: []LogEntry, only_job_or_ui: bool) usize {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        var matched: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + i) % CAPACITY;
            if (!only_job_or_ui or self.slots[idx].isJobOrUi()) {
                matched += 1;
            }
        }

        const to_skip = if (matched > out.len) matched - out.len else 0;
        var skipped: usize = 0;
        var written: usize = 0;
        i = 0;
        while (i < self.count and written < out.len) : (i += 1) {
            const idx = (self.head + i) % CAPACITY;
            const entry = self.slots[idx];
            if (only_job_or_ui and !entry.isJobOrUi()) continue;
            if (skipped < to_skip) {
                skipped += 1;
                continue;
            }
            out[written] = entry;
            written += 1;
        }
        return written;
    }

    pub fn stats(self: *EventRing) struct { count: usize, dropped: u64, total: u64 } {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        return .{ .count = self.count, .dropped = self.dropped, .total = self.total_pushed };
    }
};

test "EventRing bounds capacity, drops oldest, and applies EventFilterVTable" {
    const FilterCtx = struct {
        fn accept(_: ?*anyopaque, ev: *const abi.TelemetryEvent_ABI) bool {
            return ev.kind != .filter_evaluated;
        }
    };

    var ring = EventRing{
        .filter = .{ .accept = FilterCtx.accept },
    };

    var filtered_ev = std.mem.zeroes(abi.TelemetryEvent_ABI);
    filtered_ev.kind = .filter_evaluated;
    ring.pushAbiEvent(&filtered_ev);
    try std.testing.expectEqual(@as(usize, 0), ring.stats().count);

    var i: usize = 0;
    while (i < EventRing.CAPACITY + 10) : (i += 1) {
        var ev = std.mem.zeroes(abi.TelemetryEvent_ABI);
        ev.kind = .task_log;
        ev.count_a = i;
        ev.primary_name = abi.Slice_ABI.from("worker");
        ev.payload = abi.Slice_ABI.from("hello");
        ring.pushAbiEvent(&ev);
    }

    const st = ring.stats();
    try std.testing.expectEqual(EventRing.CAPACITY, st.count);
    try std.testing.expectEqual(@as(u64, 10), st.dropped);

    var recent: [4]LogEntry = undefined;
    const n = ring.snapshotRecent(&recent, true);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u64, EventRing.CAPACITY + 6), recent[0].count_a);
    try std.testing.expectEqual(@as(u64, EventRing.CAPACITY + 9), recent[3].count_a);
}
