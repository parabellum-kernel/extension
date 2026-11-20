const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("parabellum_sdk");
const platform = @import("parabellum_platform");
const cap = sdk.capabilities;
const env = sdk.transport.inbound.envelope;

pub const SidebarItem = struct {
    is_group: bool,
    group_name: []const u8,
    cap_index: usize = 0,
};

pub const FormFieldState = struct {
    spec: cap.FieldSpec,
    buf: std.ArrayList(u8) = .empty,
    bool_val: bool = false,
    enum_idx: usize = 0,
    err_msg: ?[]const u8 = null,

    pub fn init(alloc: Allocator, spec: cap.FieldSpec) !FormFieldState {
        var st = FormFieldState{ .spec = spec };
        if (spec.default_value) |dv| {
            switch (spec.field_type) {
                .bool => st.bool_val = std.mem.eql(u8, dv, "true") or std.mem.eql(u8, dv, "1"),
                .enum_type => {
                    for (spec.enum_values, 0..) |ev, idx| {
                        if (std.mem.eql(u8, ev, dv)) {
                            st.enum_idx = idx;
                            break;
                        }
                    }
                    try st.buf.appendSlice(alloc, dv);
                },
                else => try st.buf.appendSlice(alloc, dv),
            }
        } else if (spec.field_type == .enum_type and spec.enum_values.len > 0) {
            try st.buf.appendSlice(alloc, spec.enum_values[0]);
        }
        return st;
    }

    pub fn deinit(self: *FormFieldState, alloc: Allocator) void {
        self.buf.deinit(alloc);
    }

    pub fn setValue(self: *FormFieldState, alloc: Allocator, val: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(alloc, val);
        if (self.spec.field_type == .bool) {
            self.bool_val = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        } else if (self.spec.field_type == .enum_type) {
            for (self.spec.enum_values, 0..) |ev, idx| {
                if (std.mem.eql(u8, ev, val)) {
                    self.enum_idx = idx;
                    break;
                }
            }
        }
        self.err_msg = null;
    }

    pub fn toggleBool(self: *FormFieldState) void {
        if (self.spec.field_type != .bool) return;
        self.bool_val = !self.bool_val;
        self.err_msg = null;
    }

    pub fn cycleEnum(self: *FormFieldState, alloc: Allocator, delta: isize) !void {
        if (self.spec.field_type != .enum_type or self.spec.enum_values.len == 0) return;
        const len: isize = @intCast(self.spec.enum_values.len);
        const cur: isize = @intCast(self.enum_idx);
        const next: usize = @intCast(@mod(cur + delta, len));
        self.enum_idx = next;
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(alloc, self.spec.enum_values[next]);
        self.err_msg = null;
    }

    pub fn appendChar(self: *FormFieldState, alloc: Allocator, cp: u21) !void {
        if (self.spec.field_type == .bool or self.spec.field_type == .enum_type) return;
        var u8buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &u8buf) catch return;
        try self.buf.appendSlice(alloc, u8buf[0..n]);
        self.err_msg = null;
    }

    pub fn backspace(self: *FormFieldState) void {
        if (self.spec.field_type == .bool or self.spec.field_type == .enum_type) return;
        if (self.buf.items.len == 0) return;
        // Pop UTF-8 continuation bytes safely
        while (self.buf.items.len > 0) {
            const b = self.buf.items[self.buf.items.len - 1];
            self.buf.items.len -= 1;
            if ((b & 0b1100_0000) != 0b1000_0000) break;
        }
        self.err_msg = null;
    }

    pub fn validate(self: *FormFieldState) bool {
        self.err_msg = null;
        if (self.spec.field_type == .bool) return true;
        const val = self.buf.items;
        if (val.len == 0) {
            if (self.spec.required) {
                self.err_msg = "required";
                return false;
            }
            return true;
        }

        switch (self.spec.field_type) {
            .int64 => {
                const n = std.fmt.parseInt(i64, val, 10) catch {
                    self.err_msg = "expected int64";
                    return false;
                };
                const f: f64 = @floatFromInt(n);
                if (self.spec.min_value) |mn| if (f < mn) {
                    self.err_msg = "below min";
                    return false;
                };
                if (self.spec.max_value) |mx| if (f > mx) {
                    self.err_msg = "above max";
                    return false;
                };
            },
            .uint64 => {
                const n = std.fmt.parseInt(u64, val, 10) catch {
                    self.err_msg = "expected uint64";
                    return false;
                };
                const f: f64 = @floatFromInt(n);
                if (self.spec.min_value) |mn| if (f < mn) {
                    self.err_msg = "below min";
                    return false;
                };
                if (self.spec.max_value) |mx| if (f > mx) {
                    self.err_msg = "above max";
                    return false;
                };
            },
            .float64 => {
                const f = std.fmt.parseFloat(f64, val) catch {
                    self.err_msg = "expected float64";
                    return false;
                };
                if (self.spec.min_value) |mn| if (f < mn) {
                    self.err_msg = "below min";
                    return false;
                };
                if (self.spec.max_value) |mx| if (f > mx) {
                    self.err_msg = "above max";
                    return false;
                };
            },
            .enum_type => {
                if (self.spec.enum_values.len > 0) {
                    var ok = false;
                    for (self.spec.enum_values) |ev| {
                        if (std.mem.eql(u8, ev, val)) {
                            ok = true;
                            break;
                        }
                    }
                    if (!ok) {
                        self.err_msg = "invalid enum";
                        return false;
                    }
                }
            },
            else => {},
        }
        return true;
    }

    pub fn displayValue(self: *const FormFieldState, mask_buf: []u8) []const u8 {
        if (self.spec.field_type == .bool) {
            return if (self.bool_val) "[x] true" else "[ ] false";
        }
        if (self.spec.field_type == .enum_type) {
            if (self.spec.enum_values.len > 0) {
                return self.spec.enum_values[self.enum_idx];
            }
            return self.buf.items;
        }
        if (self.spec.field_type == .secret) {
            const n = @min(self.buf.items.len, mask_buf.len);
            @memset(mask_buf[0..n], '*');
            return mask_buf[0..n];
        }
        return self.buf.items;
    }

    /// Autocompletes `buf` against filesystem entries relative to CWD (or absolute prefix).
    /// Returns the number of matching entries found (or 0 if none).
    pub fn autocompletePath(self: *FormFieldState, alloc: Allocator, cycle_idx: usize) !usize {
        if (self.spec.field_type != .file_path and self.spec.field_type != .dir_path) return 0;
        const raw = self.buf.items;
        const only_dirs = self.spec.field_type == .dir_path;

        const slash_pos = std.mem.lastIndexOfScalar(u8, raw, '/');
        const dir_part: []const u8 = if (slash_pos) |p| (if (p == 0) "/" else raw[0..p]) else ".";
        const prefix: []const u8 = if (slash_pos) |p| raw[p + 1 ..] else raw;

        const entries = platform.fs.nativeFs().listDir(alloc, dir_part) catch return 0;
        defer platform.fs.PlatformFs.freeDirEntries(alloc, entries);

        var matches: std.ArrayList([]u8) = .empty;
        defer {
            for (matches.items) |m| alloc.free(m);
            matches.deinit(alloc);
        }

        for (entries) |ent| {
            if (only_dirs and ent.kind != .directory) continue;
            if (!std.mem.startsWith(u8, ent.name, prefix)) continue;

            const is_dir = ent.kind == .directory;
            const full = if (slash_pos) |p|
                try std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ raw[0..p], ent.name, if (is_dir) "/" else "" })
            else
                try std.fmt.allocPrint(alloc, "{s}{s}", .{ ent.name, if (is_dir) "/" else "" });
            try matches.append(alloc, full);
        }

        if (matches.items.len == 0) return 0;
        std.mem.sort([]u8, matches.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        const chosen = matches.items[cycle_idx % matches.items.len];
        try self.setValue(alloc, chosen);
        return matches.items.len;
    }
};

pub const FlatTreeRow = struct {
    id: []const u8,
    label: []const u8,
    depth: u16,
    has_children: bool,
    expanded: bool,
    fields: []const env.KeyValue,
};

pub const ResultKind = enum {
    empty,
    scalar,
    record,
    table,
    tree,
    document,
    media_blob,
    log_stream,
};

pub const ResultView = struct {
    arena: std.heap.ArenaAllocator,
    kind: ResultKind = .empty,
    status_code: i32 = 0,
    capability_id: []const u8 = "",

    scalar_text: []const u8 = "",
    record_fields: []const env.KeyValue = &.{},

    table_cols: []const []const u8 = &.{},
    table_rows: [][]const []const u8 = &.{},
    table_sort_col: ?usize = null,
    table_sort_asc: bool = true,

    tree_roots: []const env.TreeNode = &.{},
    tree_collapsed: std.StringHashMapUnmanaged(void) = .empty,
    tree_flat: std.ArrayList(FlatTreeRow) = .empty,

    doc_mime: []const u8 = "text/plain",
    doc_lines: [][]const u8 = &.{},

    media_mime: []const u8 = "application/octet-stream",
    media_bytes_len: usize = 0,

    selected_idx: usize = 0,
    scroll_y: usize = 0,

    pub fn init(backing: Allocator) ResultView {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *ResultView) void {
        self.arena.deinit();
    }

    pub fn reset(self: *ResultView) void {
        _ = self.arena.reset(.retain_capacity);
        self.kind = .empty;
        self.status_code = 0;
        self.capability_id = "";
        self.scalar_text = "";
        self.record_fields = &.{};
        self.table_cols = &.{};
        self.table_rows = &.{};
        self.table_sort_col = null;
        self.table_sort_asc = true;
        self.tree_roots = &.{};
        self.tree_collapsed = .empty;
        self.tree_flat = .empty;
        self.doc_mime = "text/plain";
        self.doc_lines = &.{};
        self.media_mime = "application/octet-stream";
        self.media_bytes_len = 0;
        self.selected_idx = 0;
        self.scroll_y = 0;
    }

    pub fn loadResponse(
        self: *ResultView,
        spec: cap.CapabilitySpec,
        status_code: i32,
        body: []const u8,
    ) !void {
        self.reset();
        const alloc = self.arena.allocator();
        self.status_code = status_code;
        self.capability_id = try alloc.dupe(u8, spec.id);

        if (status_code < 200 or status_code >= 300) {
            try self.setDocument("text/plain", body);
            return;
        }

        switch (spec.output.kind) {
            .none => {
                self.kind = .scalar;
                self.scalar_text = if (body.len > 0) try alloc.dupe(u8, body) else "OK";
            },
            .scalar => {
                if (std.json.parseFromSlice(env.ScalarEnvelope, alloc, body, .{ .ignore_unknown_fields = true })) |parsed| {
                    self.kind = .scalar;
                    self.scalar_text = try std.json.Stringify.valueAlloc(alloc, parsed.value.value, .{});
                } else |_| {
                    self.kind = .scalar;
                    self.scalar_text = try alloc.dupe(u8, body);
                }
            },
            .record => {
                if (std.json.parseFromSlice(env.RecordEnvelope, alloc, body, .{ .ignore_unknown_fields = true })) |parsed| {
                    self.kind = .record;
                    self.record_fields = parsed.value.fields;
                } else |_| {
                    if (try self.tryLoadJsonObjectAsRecord(alloc, body)) return;
                    try self.setDocument("application/json", body);
                }
            },
            .table => {
                if (std.json.parseFromSlice(env.TableEnvelope, alloc, body, .{ .ignore_unknown_fields = true })) |parsed| {
                    self.kind = .table;
                    self.table_cols = parsed.value.columns;
                    self.table_rows = try alloc.dupe([]const []const u8, parsed.value.rows);
                } else |_| {
                    if (try self.tryLoadJsonAsTable(alloc, body)) return;
                    try self.setDocument("application/json", body);
                }
            },
            .tree => {
                if (std.json.parseFromSlice(env.TreeEnvelope, alloc, body, .{ .ignore_unknown_fields = true })) |parsed| {
                    self.kind = .tree;
                    self.tree_roots = parsed.value.nodes;
                    try self.rebuildFlatTree();
                } else |_| {
                    try self.setDocument("application/json", body);
                }
            },
            .document => {
                if (std.json.parseFromSlice(env.DocumentEnvelope, alloc, body, .{ .ignore_unknown_fields = true })) |parsed| {
                    try self.setDocument(parsed.value.mime_type, parsed.value.content);
                } else |_| {
                    if (try self.tryExtractDocumentField(alloc, spec.output.mime_type orelse "text/plain", body)) return;
                    try self.setDocument(spec.output.mime_type orelse "text/plain", body);
                }
            },
            .media_blob => {
                self.kind = .media_blob;
                self.media_mime = spec.output.mime_type orelse "application/octet-stream";
                self.media_bytes_len = body.len;
            },
            .log_stream => {
                self.kind = .log_stream;
                self.scalar_text = try alloc.dupe(u8, body);
            },
        }
    }

    fn jsonValueToText(alloc: Allocator, val: std.json.Value) ![]const u8 {
        return switch (val) {
            .string => |s| try alloc.dupe(u8, s),
            .null => "null",
            .bool => |b| if (b) "true" else "false",
            .integer => |n| try std.fmt.allocPrint(alloc, "{d}", .{n}),
            .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
            .number_string => |s| try alloc.dupe(u8, s),
            else => try std.json.Stringify.valueAlloc(alloc, val, .{}),
        };
    }

    fn tryLoadJsonObjectAsRecord(self: *ResultView, alloc: Allocator, body: []const u8) !bool {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
        if (parsed.value != .object) return false;
        if (parsed.value.object.get("data_json")) |dj| {
            if (dj == .string) {
                if (try self.tryLoadJsonObjectAsRecord(alloc, dj.string)) return true;
            }
        }
        var fields: std.ArrayList(env.KeyValue) = .empty;
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            try fields.append(alloc, .{
                .key = try alloc.dupe(u8, e.key_ptr.*),
                .value = try jsonValueToText(alloc, e.value_ptr.*),
            });
        }
        self.kind = .record;
        self.record_fields = try fields.toOwnedSlice(alloc);
        return true;
    }

    fn tryLoadJsonAsTable(self: *ResultView, alloc: Allocator, body: []const u8) !bool {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
        var arr_opt: ?[]const std.json.Value = null;

        switch (parsed.value) {
            .array => |a| arr_opt = a.items,
            .object => |obj| {
                // Unwrap common container keys (`nodes`, `items`, `rows`, `entries`) or nested `data_json`
                const keys = [_][]const u8{ "nodes", "items", "rows", "entries" };
                for (keys) |k| {
                    if (obj.get(k)) |v| {
                        if (v == .array) {
                            arr_opt = v.array.items;
                            break;
                        }
                    }
                }
                if (arr_opt == null) {
                    if (obj.get("data_json")) |dj| {
                        if (dj == .string) {
                            return try self.tryLoadJsonAsTable(alloc, dj.string);
                        }
                    }
                }
            },
            else => {},
        }

        const items = arr_opt orelse return false;
        if (items.len == 0) {
            self.kind = .table;
            self.table_cols = &.{};
            self.table_rows = &.{};
            return true;
        }
        if (items[0] != .object) return false;

        var cols: std.ArrayList([]const u8) = .empty;
        var col_it = items[0].object.iterator();
        while (col_it.next()) |e| {
            try cols.append(alloc, try alloc.dupe(u8, e.key_ptr.*));
        }
        if (cols.items.len == 0) return false;

        var rows: std.ArrayList([]const []const u8) = .empty;
        for (items) |item| {
            if (item != .object) continue;
            var row = try alloc.alloc([]const u8, cols.items.len);
            for (cols.items, 0..) |col_name, ci| {
                row[ci] = if (item.object.get(col_name)) |v|
                    try jsonValueToText(alloc, v)
                else
                    "";
            }
            try rows.append(alloc, row);
        }

        self.kind = .table;
        self.table_cols = try cols.toOwnedSlice(alloc);
        self.table_rows = try rows.toOwnedSlice(alloc);
        return true;
    }

    fn tryExtractDocumentField(self: *ResultView, alloc: Allocator, fallback_mime: []const u8, body: []const u8) !bool {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
        if (parsed.value != .object) return false;
        const obj = parsed.value.object;
        const mime: []const u8 = if (obj.get("mime_type")) |m|
            (if (m == .string and m.string.len > 0) m.string else fallback_mime)
        else
            fallback_mime;
        const doc_keys = [_][]const u8{ "content", "data", "text" };
        for (doc_keys) |k| {
            if (obj.get(k)) |v| {
                if (v == .string) {
                    try self.setDocument(mime, v.string);
                    return true;
                }
            }
        }
        return false;
    }

    fn isBinaryContent(bytes: []const u8) bool {
        const sample = bytes[0..@min(bytes.len, 512)];
        if (sample.len == 0) return false;
        var non_print: usize = 0;
        for (sample) |b| {
            if (b == 0) return true;
            if (b < 0x20 and b != '\n' and b != '\r' and b != '\t') non_print += 1;
        }
        return non_print * 100 / sample.len > 15;
    }

    fn setDocument(self: *ResultView, mime: []const u8, text: []const u8) !void {
        const alloc = self.arena.allocator();
        self.kind = .document;
        self.doc_mime = try alloc.dupe(u8, mime);

        if (isBinaryContent(text)) {
            const max_preview = @min(text.len, 4096);
            var lines: std.ArrayList([]const u8) = .empty;
            var off: usize = 0;
            while (off < max_preview) : (off += 16) {
                const end = @min(max_preview, off + 16);
                const chunk = text[off..end];
                var aw: std.Io.Writer.Allocating = .init(alloc);
                const w = &aw.writer;
                try w.print("{x:0>8}: ", .{off});
                for (0..16) |i| {
                    if (i < chunk.len) {
                        try w.print("{x:0>2} ", .{chunk[i]});
                    } else {
                        try w.writeAll("   ");
                    }
                    if (i == 7) try w.writeByte(' ');
                }
                try w.writeAll(" |");
                for (chunk) |b| {
                    try w.writeByte(if (b >= 0x20 and b < 0x7f) b else '.');
                }
                try w.writeByte('|');
                try lines.append(alloc, try aw.toOwnedSlice());
            }
            if (text.len > max_preview) {
                const more = try std.fmt.allocPrint(alloc, "... ({d} total bytes, showing first {d})", .{ text.len, max_preview });
                try lines.append(alloc, more);
            }
            self.doc_lines = try lines.toOwnedSlice(alloc);
            return;
        }

        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const dup_text = if ((std.mem.eql(u8, mime, "application/json") or
            (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '['))))
        blk: {
            if (std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{})) |parsed| {
                break :blk try std.json.Stringify.valueAlloc(alloc, parsed.value, .{ .whitespace = .indent_2 });
            } else |_| {
                break :blk try alloc.dupe(u8, text);
            }
        } else try alloc.dupe(u8, text);

        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, dup_text, '\n');
        while (it.next()) |line| {
            const clean = std.mem.trimEnd(u8, line, "\r");
            try lines.append(alloc, clean);
        }
        self.doc_lines = try lines.toOwnedSlice(alloc);
    }

    pub fn rebuildFlatTree(self: *ResultView) !void {
        const alloc = self.arena.allocator();
        self.tree_flat.clearRetainingCapacity();
        try self.appendTreeNodes(alloc, self.tree_roots, 0);
        if (self.selected_idx >= self.tree_flat.items.len and self.tree_flat.items.len > 0) {
            self.selected_idx = self.tree_flat.items.len - 1;
        }
    }

    fn appendTreeNodes(self: *ResultView, alloc: Allocator, nodes: []const env.TreeNode, depth: u16) !void {
        for (nodes) |node| {
            const has_children = node.children.len > 0;
            const expanded = !self.tree_collapsed.contains(node.id);
            try self.tree_flat.append(alloc, .{
                .id = node.id,
                .label = node.label,
                .depth = depth,
                .has_children = has_children,
                .expanded = expanded,
                .fields = node.fields,
            });
            if (has_children and expanded) {
                try self.appendTreeNodes(alloc, node.children, depth + 1);
            }
        }
    }

    pub fn toggleSelectedTreeNode(self: *ResultView) !void {
        if (self.kind != .tree or self.selected_idx >= self.tree_flat.items.len) return;
        const row = self.tree_flat.items[self.selected_idx];
        if (!row.has_children) return;
        const alloc = self.arena.allocator();
        if (self.tree_collapsed.contains(row.id)) {
            _ = self.tree_collapsed.remove(row.id);
        } else {
            try self.tree_collapsed.put(alloc, row.id, {});
        }
        try self.rebuildFlatTree();
    }

    pub fn sortTableByColumn(self: *ResultView, col_idx: usize) void {
        if (self.kind != .table or col_idx >= self.table_cols.len or self.table_rows.len == 0) return;
        if (self.table_sort_col != null and self.table_sort_col.? == col_idx) {
            self.table_sort_asc = !self.table_sort_asc;
        } else {
            self.table_sort_col = col_idx;
            self.table_sort_asc = true;
        }

        const Ctx = struct {
            col: usize,
            asc: bool,
            fn lessThan(ctx: @This(), a: []const []const u8, b: []const []const u8) bool {
                const av = if (ctx.col < a.len) a[ctx.col] else "";
                const bv = if (ctx.col < b.len) b[ctx.col] else "";
                const ord = std.mem.order(u8, av, bv);
                return if (ctx.asc) ord == .lt else ord == .gt;
            }
        };
        std.mem.sort([]const []const u8, self.table_rows, Ctx{ .col = col_idx, .asc = self.table_sort_asc }, Ctx.lessThan);
    }

    pub fn itemCount(self: *const ResultView) usize {
        return switch (self.kind) {
            .record => self.record_fields.len,
            .table => self.table_rows.len,
            .tree => self.tree_flat.items.len,
            .document => self.doc_lines.len,
            else => 0,
        };
    }

    /// Returns the field value for the currently selected table row or tree node.
    pub fn selectedFieldValue(self: *const ResultView, field_name: []const u8) ?[]const u8 {
        switch (self.kind) {
            .tree => {
                if (self.selected_idx >= self.tree_flat.items.len) return null;
                const node = self.tree_flat.items[self.selected_idx];
                if (std.mem.eql(u8, field_name, "id")) return node.id;
                if (std.mem.eql(u8, field_name, "label")) return node.label;
                for (node.fields) |kv| {
                    if (std.mem.eql(u8, kv.key, field_name)) return kv.value;
                }
                return null;
            },
            .table => {
                if (self.selected_idx >= self.table_rows.len) return null;
                const row = self.table_rows[self.selected_idx];
                for (self.table_cols, 0..) |col_name, ci| {
                    if (std.mem.eql(u8, col_name, field_name) and ci < row.len) {
                        return row[ci];
                    }
                }
                return null;
            },
            .record => {
                for (self.record_fields) |kv| {
                    if (std.mem.eql(u8, kv.key, field_name)) return kv.value;
                }
                return null;
            },
            else => return null,
        }
    }
};

pub const CatalogState = struct {
    alloc: Allocator,
    catalog: cap.CapabilityCatalog,
    sidebar_items: std.ArrayList(SidebarItem) = .empty,
    selected_sidebar: usize = 0,
    active_cap_idx: ?usize = null,
    form_fields: std.ArrayList(FormFieldState) = .empty,
    active_field_idx: usize = 0,
    result: ResultView,

    pub fn init(alloc: Allocator, catalog: cap.CapabilityCatalog) !CatalogState {
        var st = CatalogState{
            .alloc = alloc,
            .catalog = catalog,
            .result = ResultView.init(alloc),
        };
        try st.rebuildSidebar("");
        if (catalog.capabilities.len > 0) {
            try st.selectCapability(0);
        }
        return st;
    }

    pub fn deinit(self: *CatalogState) void {
        self.clearForm();
        self.form_fields.deinit(self.alloc);
        self.sidebar_items.deinit(self.alloc);
        self.result.deinit();
    }

    fn clearForm(self: *CatalogState) void {
        for (self.form_fields.items) |*f| f.deinit(self.alloc);
        self.form_fields.clearRetainingCapacity();
        self.active_field_idx = 0;
    }

    pub fn rebuildSidebar(self: *CatalogState, filter: []const u8) !void {
        self.sidebar_items.clearRetainingCapacity();

        // Collect distinct groups in order of appearance
        var groups: std.ArrayList([]const u8) = .empty;
        defer groups.deinit(self.alloc);

        for (self.catalog.capabilities) |spec| {
            if (!matchesFilter(spec, filter)) continue;
            var found = false;
            for (groups.items) |g| {
                if (std.mem.eql(u8, g, spec.group)) {
                    found = true;
                    break;
                }
            }
            if (!found) try groups.append(self.alloc, spec.group);
        }

        for (groups.items) |g| {
            try self.sidebar_items.append(self.alloc, .{
                .is_group = true,
                .group_name = g,
            });
            for (self.catalog.capabilities, 0..) |spec, idx| {
                if (!std.mem.eql(u8, spec.group, g)) continue;
                if (!matchesFilter(spec, filter)) continue;
                try self.sidebar_items.append(self.alloc, .{
                    .is_group = false,
                    .group_name = g,
                    .cap_index = idx,
                });
            }
        }

        self.selected_sidebar = 0;
        for (self.sidebar_items.items, 0..) |it, idx| {
            if (!it.is_group) {
                self.selected_sidebar = idx;
                break;
            }
        }
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    fn isHiddenInTui(spec: cap.CapabilitySpec) bool {
        for (spec.hints) |kv| {
            if (std.mem.eql(u8, kv.key, "tui.hidden") and
                (std.mem.eql(u8, kv.value, "true") or std.mem.eql(u8, kv.value, "1")))
            {
                return true;
            }
        }
        return false;
    }

    fn matchesFilter(spec: cap.CapabilitySpec, filter: []const u8) bool {
        if (isHiddenInTui(spec)) return false;
        if (filter.len == 0) return true;
        if (containsIgnoreCase(spec.id, filter)) return true;
        if (containsIgnoreCase(spec.group, filter)) return true;
        if (spec.title) |t| if (containsIgnoreCase(t, filter)) return true;
        return false;
    }

    pub fn selectCapability(self: *CatalogState, cap_idx: usize) !void {
        if (cap_idx >= self.catalog.capabilities.len) return;
        self.clearForm();
        self.active_cap_idx = cap_idx;
        const spec = self.catalog.capabilities[cap_idx];
        for (spec.inputs) |inp| {
            try self.form_fields.append(self.alloc, try FormFieldState.init(self.alloc, inp));
        }
    }

    pub fn selectCapabilityById(self: *CatalogState, cap_id: []const u8) !bool {
        for (self.catalog.capabilities, 0..) |spec, idx| {
            if (std.mem.eql(u8, spec.id, cap_id)) {
                try self.selectCapability(idx);
                for (self.sidebar_items.items, 0..) |it, sidx| {
                    if (!it.is_group and it.cap_index == idx) {
                        self.selected_sidebar = sidx;
                        break;
                    }
                }
                return true;
            }
        }
        return false;
    }

    pub fn activeCapability(self: *const CatalogState) ?cap.CapabilitySpec {
        const idx = self.active_cap_idx orelse return null;
        if (idx >= self.catalog.capabilities.len) return null;
        return self.catalog.capabilities[idx];
    }

    pub fn validateForm(self: *CatalogState) bool {
        var all_ok = true;
        for (self.form_fields.items) |*f| {
            if (!f.validate()) all_ok = false;
        }
        return all_ok;
    }

    pub fn serializeFormJson(self: *const CatalogState, alloc: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        const w = &aw.writer;

        try w.writeByte('{');
        var first = true;
        for (self.form_fields.items) |f| {
            if (f.spec.field_type != .bool and f.buf.items.len == 0 and !f.spec.required) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try std.json.Stringify.encodeJsonString(f.spec.name, .{}, w);
            try w.writeByte(':');
            switch (f.spec.field_type) {
                .bool => try w.writeAll(if (f.bool_val) "true" else "false"),
                .int64, .uint64, .float64 => try w.writeAll(if (f.buf.items.len > 0) f.buf.items else "0"),
                else => try std.json.Stringify.encodeJsonString(f.buf.items, .{}, w),
            }
        }
        try w.writeByte('}');
        return try aw.toOwnedSlice();
    }

    /// Resolves matching `ActionLink`s from the active capability against the selected output item.
    pub fn matchingActions(self: *const CatalogState, out: []cap.ActionLink) usize {
        const spec = self.activeCapability() orelse return 0;
        var n: usize = 0;
        for (spec.actions) |act| {
            if (n >= out.len) break;
            if (act.condition_field) |cf| {
                const val = self.result.selectedFieldValue(cf) orelse continue;
                if (act.condition_equals) |eq| {
                    if (!std.mem.eql(u8, val, eq)) continue;
                }
            }
            out[n] = act;
            n += 1;
        }
        return n;
    }

    /// Applies an `ActionLink`: switches to `act.capability_id` and populates mapped inputs.
    pub fn applyActionLink(self: *CatalogState, act: cap.ActionLink) !bool {
        // Capture mapped values before switching capability/result
        var mapped_vals: [16]struct { name: []const u8, val: []const u8 } = undefined;
        var mcount: usize = 0;
        for (act.param_map) |pm| {
            if (mcount >= mapped_vals.len) break;
            if (self.result.selectedFieldValue(pm.source_field)) |v| {
                mapped_vals[mcount] = .{ .name = pm.target_input, .val = v };
                mcount += 1;
            }
        }

        if (!try self.selectCapabilityById(act.capability_id)) return false;

        for (mapped_vals[0..mcount]) |mv| {
            for (self.form_fields.items) |*f| {
                if (std.mem.eql(u8, f.spec.name, mv.name)) {
                    try f.setValue(self.alloc, mv.val);
                }
            }
        }
        return true;
    }
};

test "CatalogState groups capabilities, validates form, serializes JSON, and resolves ActionLinks" {
    const alloc = std.testing.allocator;
    const catalog = cap.CapabilityCatalog{
        .id = "demo",
        .name = "Demo",
        .capabilities = &.{
            .{
                .id = "vfs.ls",
                .group = "vfs",
                .title = "List VFS",
                .inputs = &.{
                    .{ .name = "path", .field_type = .dir_path, .default_value = "/" },
                    .{ .name = "limit", .field_type = .uint64, .min_value = 1, .max_value = 100, .default_value = "25" },
                    .{ .name = "hidden", .field_type = .bool, .default_value = "false" },
                },
                .output = .{ .kind = .tree },
                .actions = &.{
                    .{
                        .label = "Read File",
                        .capability_id = "vfs.read",
                        .condition_field = "type",
                        .condition_equals = "file",
                        .param_map = &.{.{ .target_input = "path", .source_field = "id" }},
                    },
                },
            },
            .{
                .id = "vfs.read",
                .group = "vfs",
                .title = "Read File",
                .inputs = &.{
                    .{ .name = "path", .field_type = .file_path, .required = true },
                },
                .output = .{ .kind = .document },
            },
        },
    };

    var st = try CatalogState.init(alloc, catalog);
    defer st.deinit();

    try std.testing.expect(st.validateForm());
    const json = try st.serializeFormJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\":\"/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"limit\":25") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hidden\":false") != null);

    // Load tree response and test ActionLink resolution
    const tree_json =
        \\{"nodes":[{"id":"/notes.md","label":"notes.md","fields":[{"key":"type","value":"file"}]}]}
    ;
    try st.result.loadResponse(st.activeCapability().?, 200, tree_json);
    try std.testing.expectEqual(ResultKind.tree, st.result.kind);

    var acts: [4]cap.ActionLink = undefined;
    const n = st.matchingActions(&acts);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(try st.applyActionLink(acts[0]));
    try std.testing.expectEqualStrings("vfs.read", st.activeCapability().?.id);
    try std.testing.expectEqualStrings("/notes.md", st.form_fields.items[0].buf.items);

    // Generic JSON object -> .record, generic JSON array -> .table, document -> pretty JSON
    try st.result.loadResponse(.{ .id = "m", .output = .{ .kind = .record } }, 200, "{\"hits\":42,\"ok\":true}");
    try std.testing.expectEqual(ResultKind.record, st.result.kind);
    try std.testing.expectEqual(@as(usize, 2), st.result.record_fields.len);

    try st.result.loadResponse(.{ .id = "ls", .output = .{ .kind = .table } }, 200, "{\"nodes\":[{\"inode_id\":\"1\",\"name\":\"a.txt\"}]}");
    try std.testing.expectEqual(ResultKind.table, st.result.kind);
    try std.testing.expectEqual(@as(usize, 2), st.result.table_cols.len);
    try std.testing.expectEqual(@as(usize, 1), st.result.table_rows.len);

    try st.result.loadResponse(.{ .id = "doc", .output = .{ .kind = .document } }, 200, "{\"a\":1,\"b\":2}");
    try std.testing.expectEqual(ResultKind.document, st.result.kind);
    try std.testing.expect(st.result.doc_lines.len > 1);

    // Document extracts "data" field and formats binary content as hex dump
    try st.result.loadResponse(.{ .id = "read", .output = .{ .kind = .document } }, 200, "{\"mime_type\":\"text/plain\",\"data\":\"line1\\nline2\"}");
    try std.testing.expectEqual(@as(usize, 2), st.result.doc_lines.len);
    try std.testing.expectEqualStrings("line1", st.result.doc_lines[0]);

    try st.result.loadResponse(.{ .id = "bin", .output = .{ .kind = .document } }, 200, "%PDF\x00\x01\x02");
    try std.testing.expect(std.mem.indexOf(u8, st.result.doc_lines[0], "25 50 44 46") != null);
}
