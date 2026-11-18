//! Self-contained directory change watcher (depends only on `std` + libc).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OnChangeFn = *const fn (ctx: *anyopaque, full_path: []const u8, file_name: []const u8) void;

pub const WatchTarget = struct {
    dir_path: []const u8 = "./sync_dir",
    partition: []const u8 = "official_docs",
};

pub fn parseWatchTarget(listen_addr: []const u8) WatchTarget {
    if (listen_addr.len == 0 or std.mem.eql(u8, listen_addr, "127.0.0.1:8080")) {
        return .{};
    }
    if (std.mem.indexOfScalar(u8, listen_addr, '?')) |q| {
        const dir = if (q > 0) listen_addr[0..q] else "./sync_dir";
        const query = listen_addr[q + 1 ..];
        var part: []const u8 = "official_docs";
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |kv| {
            if (std.mem.startsWith(u8, kv, "partition=")) {
                const v = kv["partition=".len..];
                if (v.len > 0) part = v;
            }
        }
        return .{ .dir_path = dir, .partition = part };
    }
    return .{ .dir_path = listen_addr };
}

fn isIgnoredName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    if (name[name.len - 1] == '~') return true;
    if (std.mem.endsWith(u8, name, ".tmp") or std.mem.endsWith(u8, name, ".swp")) return true;
    return false;
}

pub const FsWatcher = struct {
    allocator: Allocator,
    dir_path: []const u8,
    seen_mtimes: std.StringHashMapUnmanaged(i128) = .empty,

    pub fn init(allocator: Allocator, dir_path: []const u8) FsWatcher {
        return .{
            .allocator = allocator,
            .dir_path = dir_path,
        };
    }

    pub fn deinit(self: *FsWatcher) void {
        var it = self.seen_mtimes.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.seen_mtimes.deinit(self.allocator);
    }

    pub fn scanOnce(self: *FsWatcher, io: std.Io, emit_events: bool, ctx: *anyopaque, on_change: ?OnChangeFn) !void {
        std.Io.Dir.cwd().createDirPath(io, self.dir_path) catch {};
        var dir = std.Io.Dir.cwd().openDir(io, self.dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |ent| {
            if (ent.kind != .file) continue;
            if (isIgnoredName(ent.name)) continue;

            const f = dir.openFile(io, ent.name, .{}) catch continue;
            const st = f.stat(io) catch {
                f.close(io);
                continue;
            };
            f.close(io);

            const mtime_ns: i128 = st.mtime.nanoseconds;
            if (self.seen_mtimes.getPtr(ent.name)) |prev| {
                if (mtime_ns > prev.*) {
                    prev.* = mtime_ns;
                    if (emit_events) {
                        if (on_change) |cb| {
                            const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, ent.name });
                            defer self.allocator.free(full);
                            cb(ctx, full, ent.name);
                        }
                    }
                }
            } else {
                const owned = try self.allocator.dupe(u8, ent.name);
                errdefer self.allocator.free(owned);
                try self.seen_mtimes.put(self.allocator, owned, mtime_ns);
                if (emit_events) {
                    if (on_change) |cb| {
                        const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, ent.name });
                        defer self.allocator.free(full);
                        cb(ctx, full, ent.name);
                    }
                }
            }
        }
    }

    pub fn watchLoop(self: *FsWatcher, io: std.Io, ctx: *anyopaque, on_change: OnChangeFn) !void {
        // Seed initial files without emitting events, then poll for modifications/new files.
        try self.scanOnce(io, false, ctx, null);
        while (true) {
            var req = std.c.timespec{ .sec = 0, .nsec = 500_000_000 };
            _ = std.c.nanosleep(&req, null);
            self.scanOnce(io, true, ctx, on_change) catch {};
        }
    }
};

test "parseWatchTarget parses directory and optional partition" {
    const t1 = parseWatchTarget("./sync_dir?partition=archives");
    try std.testing.expectEqualStrings("./sync_dir", t1.dir_path);
    try std.testing.expectEqualStrings("archives", t1.partition);

    const t2 = parseWatchTarget("127.0.0.1:8080");
    try std.testing.expectEqualStrings("./sync_dir", t2.dir_path);
    try std.testing.expectEqualStrings("official_docs", t2.partition);
}
