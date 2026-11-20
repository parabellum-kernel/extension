const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;
const cap = sdk.capabilities;
const inbound = sdk.transport.inbound;
const vtables = inbound.vtables;

const term = @import("terminal.zig");
const Screen = term.Screen;
const PanelSurface = term.PanelSurface;
const Style = term.Style;
const Key = term.Key;
const RawTerminal = term.RawTerminal;

const EventRing = @import("event_ring.zig").EventRing;
const LogEntry = @import("event_ring.zig").LogEntry;
const cs = @import("catalog_state.zig");
const CatalogState = cs.CatalogState;
const ResultKind = cs.ResultKind;

pub const CustomRenderer = struct {
    capability_id: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    vtable: vtables.RendererVTable,
};

pub const PanelDock = enum {
    left,
    main_top,
    main_bottom,
    right,
    bottom,
};

pub const CustomPanel = struct {
    id: []const u8,
    title: []const u8,
    dock: PanelDock = .right,
    visible: bool = true,
    ctx: ?*anyopaque = null,
    render: *const fn (ctx: ?*anyopaque, surface: PanelSurface, focused: bool) void,
    handle_key: ?*const fn (ctx: ?*anyopaque, key: Key, dispatcher: inbound.HostDispatcher) anyerror!bool = null,
};

pub const Config = struct {
    title: ?[]const u8 = null,
    event_filter: ?vtables.EventFilterVTable = null,
    keymap: []const vtables.KeymapEntry = &.{},
    custom_renderers: []const CustomRenderer = &.{},
    extra_panels: []const CustomPanel = &.{},
    show_logs: bool = true,
};

pub const PanelKind = enum {
    sidebar,
    form,
    output,
    logs,
    custom,
};

pub const PanelEntry = struct {
    id: []const u8,
    title: []const u8,
    dock: PanelDock,
    kind: PanelKind,
    visible: bool = true,
    custom: ?CustomPanel = null,
};

pub const Modal = enum {
    none,
    palette,
    help,
    actions,
};

pub const HistoryEntry = struct {
    cap_idx: usize,
    field_vals: [][]u8,

    pub fn deinit(self: *HistoryEntry, alloc: Allocator) void {
        for (self.field_vals) |v| alloc.free(v);
        alloc.free(self.field_vals);
    }
};

pub const TuiApp = struct {
    alloc: Allocator,
    config: Config,
    state: CatalogState,
    ring: *EventRing,
    panels: std.ArrayList(PanelEntry) = .empty,
    focus_idx: usize = 0,
    modal: Modal = .none,
    logs_only_job_ui: bool = true,
    logs_scroll_from_bottom: usize = 0,
    should_quit: bool = false,

    nav_history: std.ArrayList(HistoryEntry) = .empty,

    palette_query: std.ArrayList(u8) = .empty,
    action_choices: [8]cap.ActionLink = undefined,
    action_count: usize = 0,
    action_selected: usize = 0,

    table_sort_next_col: usize = 0,
    path_complete_cycle: usize = 0,
    status_msg: [128]u8 = undefined,
    status_len: usize = 0,
    raw_last_body: []u8 = &.{},

    pub fn init(
        alloc: Allocator,
        catalog: cap.CapabilityCatalog,
        ring: *EventRing,
        config: Config,
    ) !TuiApp {
        if (config.event_filter) |ef| {
            ring.filter = ef;
        }
        var app = TuiApp{
            .alloc = alloc,
            .config = config,
            .state = try CatalogState.init(alloc, catalog),
            .ring = ring,
        };
        try app.panels.appendSlice(alloc, &.{
            .{ .id = "capabilities", .title = "Capabilities", .dock = .left, .kind = .sidebar, .visible = true },
            .{ .id = "form", .title = "Form", .dock = .main_top, .kind = .form, .visible = true },
            .{ .id = "output", .title = "Output", .dock = .main_bottom, .kind = .output, .visible = true },
            .{ .id = "logs", .title = "Telemetry Logs", .dock = .bottom, .kind = .logs, .visible = config.show_logs },
        });
        for (config.extra_panels) |ep| {
            try app.panels.append(alloc, .{
                .id = ep.id,
                .title = ep.title,
                .dock = ep.dock,
                .kind = .custom,
                .visible = ep.visible,
                .custom = ep,
            });
        }
        app.setStatus("Ready. 1-9: focus panel | z: zoom | Alt+1-9: hide/show | ?: help | F5: run | q: quit");
        return app;
    }

    pub fn deinit(self: *TuiApp) void {
        if (self.raw_last_body.len > 0) self.alloc.free(self.raw_last_body);
        for (self.nav_history.items) |*h| h.deinit(self.alloc);
        self.nav_history.deinit(self.alloc);
        self.palette_query.deinit(self.alloc);
        self.panels.deinit(self.alloc);
        self.state.deinit();
    }

    fn pushNavHistory(self: *TuiApp) !void {
        const cap_idx = self.state.active_cap_idx orelse return;
        const n = self.state.form_fields.items.len;
        var vals = try self.alloc.alloc([]u8, n);
        var initialized: usize = 0;
        errdefer {
            for (vals[0..initialized]) |v| self.alloc.free(v);
            self.alloc.free(vals);
        }
        for (self.state.form_fields.items, 0..) |f, i| {
            const raw: []const u8 = if (f.spec.field_type == .bool)
                (if (f.bool_val) "true" else "false")
            else
                f.buf.items;
            vals[i] = try self.alloc.dupe(u8, raw);
            initialized += 1;
        }
        if (self.nav_history.items.len >= 32) {
            var oldest = self.nav_history.orderedRemove(0);
            oldest.deinit(self.alloc);
        }
        try self.nav_history.append(self.alloc, .{
            .cap_idx = cap_idx,
            .field_vals = vals,
        });
    }

    fn navigateBack(self: *TuiApp, dispatcher: inbound.HostDispatcher) !void {
        if (self.nav_history.items.len == 0) {
            self.setStatus("Already at top level");
            return;
        }
        var entry = self.nav_history.pop().?;
        defer entry.deinit(self.alloc);

        try self.state.selectCapability(entry.cap_idx);
        for (self.state.form_fields.items, 0..) |*f, i| {
            if (i < entry.field_vals.len) {
                try f.setValue(self.alloc, entry.field_vals[i]);
            }
        }
        try self.executeActiveCapability(dispatcher);
    }

    fn focusedPanelKind(self: *const TuiApp) PanelKind {
        if (self.focus_idx < self.panels.items.len) {
            return self.panels.items[self.focus_idx].kind;
        }
        return .sidebar;
    }

    fn focusKind(self: *TuiApp, kind: PanelKind) void {
        for (self.panels.items, 0..) |p, idx| {
            if (p.kind == kind and p.visible) {
                self.focus_idx = idx;
                return;
            }
        }
    }

    fn cycleFocus(self: *TuiApp, delta: isize) void {
        const len = self.panels.items.len;
        if (len == 0) return;
        var idx: isize = @intCast(self.focus_idx);
        var step: usize = 0;
        while (step < len) : (step += 1) {
            idx = @mod(idx + delta, @as(isize, @intCast(len)));
            if (self.panels.items[@intCast(idx)].visible) {
                self.focus_idx = @intCast(idx);
                return;
            }
        }
    }

    pub fn setStatus(self: *TuiApp, msg: []const u8) void {
        const n = @min(msg.len, self.status_msg.len);
        @memcpy(self.status_msg[0..n], msg[0..n]);
        self.status_len = n;
    }

    fn setStatusFmt(self: *TuiApp, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_msg, fmt, args) catch "Status";
        self.status_len = s.len;
    }

    pub fn statusSlice(self: *const TuiApp) []const u8 {
        return self.status_msg[0..self.status_len];
    }

    pub fn run(self: *TuiApp, dispatcher: inbound.HostDispatcher) !void {
        var tty = RawTerminal{};
        try tty.enter();
        defer tty.leave();

        // Setup wakeup pipe so kernel telemetry wakes the TUI immediately
        var pipe_fds: [2]std.c.fd_t = .{ -1, -1 };
        const has_pipe = std.c.pipe(&pipe_fds) == 0;
        if (has_pipe) {
            self.ring.wakeup_fd = pipe_fds[1];
        }
        defer {
            self.ring.wakeup_fd = null;
            if (has_pipe) {
                _ = std.c.close(pipe_fds[0]);
                _ = std.c.close(pipe_fds[1]);
            }
        }

        var screen = Screen.init(self.alloc);
        defer screen.deinit();

        var out_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer out_buf.deinit();

        var in_buf: [256]u8 = undefined;
        var pending_len: usize = 0;

        while (!self.should_quit) {
            const sz = tty.getSize();
            try screen.resize(sz.w, sz.h);
            self.render(&screen);

            out_buf.clearRetainingCapacity();
            try screen.renderDiff(&out_buf.writer);
            if (out_buf.written().len > 0) {
                tty.writeAll(out_buf.written());
            }

            var stderr_buf: [512]u8 = undefined;
            const poll_res = tty.pollRead(
                if (has_pipe) pipe_fds[0] else null,
                100,
                in_buf[pending_len..],
                &stderr_buf,
            );
            if (poll_res.stderr_len > 0) {
                var it = std.mem.splitScalar(u8, stderr_buf[0..poll_res.stderr_len], '\n');
                while (it.next()) |line| {
                    const clean = std.mem.trim(u8, line, "\r ");
                    if (clean.len == 0) continue;
                    var ev = std.mem.zeroes(abi.TelemetryEvent_ABI);
                    ev.kind = .task_log;
                    ev.primary_name = abi.Slice_ABI.from("engine");
                    ev.payload = abi.Slice_ABI.from(clean);
                    self.ring.pushAbiEvent(&ev);
                }
            }
            pending_len += poll_res.stdin_len;

            var offset: usize = 0;
            while (offset < pending_len) {
                const parsed = term.parseKey(in_buf[offset..pending_len]) orelse break;
                offset += parsed.consumed;
                try self.handleKey(parsed.key, dispatcher);
            }
            if (offset > 0 and offset < pending_len) {
                std.mem.copyForwards(u8, in_buf[0 .. pending_len - offset], in_buf[offset..pending_len]);
            }
            pending_len -= offset;
        }
    }

    pub fn handleKey(self: *TuiApp, key: Key, dispatcher: inbound.HostDispatcher) !void {
        if (key == .ctrl_c or key == .ctrl_q) {
            self.should_quit = true;
            return;
        }

        switch (self.modal) {
            .help => {
                if (key == .escape or key == .enter or (key == .char and (key.char == '?' or key.char == 'q'))) {
                    self.modal = .none;
                }
                return;
            },
            .palette => {
                try self.handlePaletteKey(key);
                return;
            },
            .actions => {
                try self.handleActionsKey(key, dispatcher);
                return;
            },
            .none => {},
        }

        // Global shortcuts
        switch (key) {
            .tab => {
                self.cycleFocus(1);
                return;
            },
            .back_tab => {
                self.cycleFocus(-1);
                return;
            },
            .f5 => {
                try self.executeActiveCapability(dispatcher);
                return;
            },
            .ctrl_l => {
                for (self.panels.items, 0..) |p, idx| {
                    if (p.kind == .logs) {
                        self.togglePanelAt(idx);
                        break;
                    }
                }
                return;
            },
            .alt_char => |ac| {
                if (ac >= '1' and ac <= '9') {
                    const idx: usize = @intCast(ac - '1');
                    self.togglePanelAt(idx);
                    return;
                }
            },
            .char => |cp| {
                // App-level KeymapVTable check (when not typing in a form text field)
                const typing_in_form = self.focusedPanelKind() == .form and
                    self.state.active_field_idx < self.state.form_fields.items.len and
                    self.state.form_fields.items[self.state.active_field_idx].spec.field_type != .bool and
                    self.state.form_fields.items[self.state.active_field_idx].spec.field_type != .enum_type;

                if (!typing_in_form) {
                    if (cp == 'q') {
                        self.should_quit = true;
                        return;
                    }
                    if (cp == '?') {
                        self.modal = .help;
                        return;
                    }
                    if (cp == ':' or cp == '/') {
                        self.palette_query.clearRetainingCapacity();
                        self.modal = .palette;
                        return;
                    }
                    if (cp == 'z') {
                        self.toggleZoomFocused();
                        return;
                    }
                    if (cp >= '1' and cp <= '9') {
                        const idx: usize = @intCast(cp - '1');
                        if (idx < self.panels.items.len) {
                            self.panels.items[idx].visible = true;
                            self.focus_idx = idx;
                            return;
                        }
                    }
                    if (cp <= 0x7f) {
                        const c: u8 = @intCast(cp);
                        for (self.config.keymap) |km| {
                            if (km.key.len == 1 and km.key[0] == c) {
                                if (try self.state.selectCapabilityById(km.capability_id)) {
                                    self.focusKind(.form);
                                    self.setStatusFmt("Keymap -> {s}", .{km.capability_id});
                                }
                                return;
                            }
                        }
                    }
                }
            },
            else => {},
        }

        if (self.focus_idx >= self.panels.items.len) return;
        const p = self.panels.items[self.focus_idx];
        switch (p.kind) {
            .sidebar => try self.handleSidebarKey(key, dispatcher),
            .form => try self.handleFormKey(key, dispatcher),
            .output => try self.handleOutputKey(key, dispatcher),
            .logs => self.handleLogsKey(key),
            .custom => {
                if (p.custom) |cp| {
                    if (cp.handle_key) |hk| {
                        _ = try hk(cp.ctx, key, dispatcher);
                    }
                }
            },
        }
    }

    fn handlePaletteKey(self: *TuiApp, key: Key) !void {
        switch (key) {
            .escape => {
                self.palette_query.clearRetainingCapacity();
                try self.state.rebuildSidebar("");
                self.modal = .none;
            },
            .enter => {
                self.modal = .none;
                if (self.state.selected_sidebar < self.state.sidebar_items.items.len) {
                    const it = self.state.sidebar_items.items[self.state.selected_sidebar];
                    if (!it.is_group) {
                        try self.state.selectCapability(it.cap_index);
                        self.focusKind(.form);
                    }
                }
            },
            .backspace => {
                if (self.palette_query.items.len > 0) {
                    self.palette_query.items.len -= 1;
                    try self.state.rebuildSidebar(self.palette_query.items);
                }
            },
            .char => |cp| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return;
                try self.palette_query.appendSlice(self.alloc, buf[0..n]);
                try self.state.rebuildSidebar(self.palette_query.items);
            },
            .up => self.moveSidebar(-1),
            .down => self.moveSidebar(1),
            else => {},
        }
    }

    fn handleActionsKey(self: *TuiApp, key: Key, dispatcher: inbound.HostDispatcher) !void {
        switch (key) {
            .escape => self.modal = .none,
            .up => {
                if (self.action_selected > 0) self.action_selected -= 1;
            },
            .down => {
                if (self.action_selected + 1 < self.action_count) self.action_selected += 1;
            },
            .enter => {
                self.modal = .none;
                if (self.action_selected < self.action_count) {
                    const act = self.action_choices[self.action_selected];
                    try self.pushNavHistory();
                    if (try self.state.applyActionLink(act)) {
                        if (self.state.validateForm()) {
                            try self.executeActiveCapability(dispatcher);
                        } else {
                            self.focusKind(.form);
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn moveSidebar(self: *TuiApp, delta: isize) void {
        const items = self.state.sidebar_items.items;
        if (items.len == 0) return;
        var idx: isize = @intCast(self.state.selected_sidebar);
        var steps: usize = 0;
        while (steps < items.len) : (steps += 1) {
            idx = @mod(idx + delta, @as(isize, @intCast(items.len)));
            if (!items[@intCast(idx)].is_group) {
                self.state.selected_sidebar = @intCast(idx);
                return;
            }
        }
    }

    fn handleSidebarKey(self: *TuiApp, key: Key, dispatcher: inbound.HostDispatcher) !void {
        switch (key) {
            .up => self.moveSidebar(-1),
            .down => self.moveSidebar(1),
            .enter => {
                if (self.state.selected_sidebar < self.state.sidebar_items.items.len) {
                    const it = self.state.sidebar_items.items[self.state.selected_sidebar];
                    if (!it.is_group) {
                        try self.state.selectCapability(it.cap_index);
                        if (self.state.form_fields.items.len == 0) {
                            try self.executeActiveCapability(dispatcher);
                        } else {
                            self.focusKind(.form);
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn handleFormKey(self: *TuiApp, key: Key, dispatcher: inbound.HostDispatcher) !void {
        const total_rows = self.state.form_fields.items.len + 1; // +1 for Run button
        switch (key) {
            .up => {
                if (self.state.active_field_idx > 0) self.state.active_field_idx -= 1;
            },
            .down => {
                if (self.state.active_field_idx + 1 < total_rows) self.state.active_field_idx += 1;
            },
            .enter => {
                if (self.state.active_field_idx >= self.state.form_fields.items.len) {
                    try self.executeActiveCapability(dispatcher);
                } else {
                    const f = &self.state.form_fields.items[self.state.active_field_idx];
                    if (f.spec.field_type == .bool) {
                        f.toggleBool();
                    } else {
                        self.state.active_field_idx += 1;
                    }
                }
            },
            .left => {
                if (self.state.active_field_idx < self.state.form_fields.items.len) {
                    const f = &self.state.form_fields.items[self.state.active_field_idx];
                    if (f.spec.field_type == .enum_type) try f.cycleEnum(self.alloc, -1);
                    if (f.spec.field_type == .bool) f.toggleBool();
                }
            },
            .right => {
                if (self.state.active_field_idx < self.state.form_fields.items.len) {
                    const f = &self.state.form_fields.items[self.state.active_field_idx];
                    if (f.spec.field_type == .enum_type) {
                        try f.cycleEnum(self.alloc, 1);
                    } else if (f.spec.field_type == .bool) {
                        f.toggleBool();
                    } else if (f.spec.field_type == .file_path or f.spec.field_type == .dir_path) {
                        const n = try f.autocompletePath(self.alloc, self.path_complete_cycle);
                        if (n > 0) {
                            self.path_complete_cycle += 1;
                            self.setStatusFmt("Path matches: {d} (Right: next)", .{n});
                        } else {
                            self.setStatus("No matching path");
                        }
                    }
                }
            },
            .backspace => {
                self.path_complete_cycle = 0;
                if (self.state.active_field_idx < self.state.form_fields.items.len) {
                    self.state.form_fields.items[self.state.active_field_idx].backspace();
                }
            },
            .char => |cp| {
                self.path_complete_cycle = 0;
                if (self.state.active_field_idx < self.state.form_fields.items.len) {
                    const f = &self.state.form_fields.items[self.state.active_field_idx];
                    if (f.spec.field_type == .bool and cp == ' ') {
                        f.toggleBool();
                    } else if (f.spec.field_type == .enum_type and cp == ' ') {
                        try f.cycleEnum(self.alloc, 1);
                    } else {
                        try f.appendChar(self.alloc, cp);
                    }
                }
            },
            else => {},
        }
    }

    fn handleOutputKey(self: *TuiApp, key: Key, dispatcher: inbound.HostDispatcher) !void {
        const count = self.state.result.itemCount();
        switch (key) {
            .up => {
                if (self.state.result.selected_idx > 0) {
                    self.state.result.selected_idx -= 1;
                } else if (self.state.result.scroll_y > 0) {
                    self.state.result.scroll_y -= 1;
                }
            },
            .down => {
                if (count > 0 and self.state.result.selected_idx + 1 < count) {
                    self.state.result.selected_idx += 1;
                }
            },
            .page_up => {
                self.state.result.selected_idx -|= 10;
            },
            .page_down => {
                if (count > 0) {
                    self.state.result.selected_idx = @min(count - 1, self.state.result.selected_idx + 10);
                }
            },
            .left, .right => {
                if (self.state.result.kind == .tree) {
                    try self.state.result.toggleSelectedTreeNode();
                }
            },
            .enter => {
                const n = self.state.matchingActions(&self.action_choices);
                if (n == 1) {
                    try self.pushNavHistory();
                    if (try self.state.applyActionLink(self.action_choices[0])) {
                        if (self.state.validateForm()) {
                            try self.executeActiveCapability(dispatcher);
                        } else {
                            self.focusKind(.form);
                        }
                    }
                } else if (n > 1) {
                    self.action_count = n;
                    self.action_selected = 0;
                    self.modal = .actions;
                } else if (self.state.result.kind == .tree) {
                    try self.state.result.toggleSelectedTreeNode();
                }
            },
            .backspace => try self.navigateBack(dispatcher),
            .char => |cp| {
                if (cp == 'b') {
                    try self.navigateBack(dispatcher);
                } else if (cp == ' ' and self.state.result.kind == .tree) {
                    try self.state.result.toggleSelectedTreeNode();
                } else if (cp == 's' and self.state.result.kind == .table and self.state.result.table_cols.len > 0) {
                    const col = self.table_sort_next_col % self.state.result.table_cols.len;
                    self.state.result.sortTableByColumn(col);
                    self.table_sort_next_col = (col + 1) % self.state.result.table_cols.len;
                    self.setStatusFmt("Sorted by column: {s}", .{self.state.result.table_cols[col]});
                } else if (cp == 'a') {
                    const n = self.state.matchingActions(&self.action_choices);
                    if (n > 0) {
                        self.action_count = n;
                        self.action_selected = 0;
                        self.modal = .actions;
                    }
                }
            },
            else => {},
        }
    }

    fn toggleZoomFocused(self: *TuiApp) void {
        var visible_count: usize = 0;
        for (self.panels.items) |p| {
            if (p.visible) visible_count += 1;
        }
        if (visible_count <= 1) {
            for (self.panels.items) |*p| p.visible = true;
            self.setStatus("Restored all panels");
        } else {
            for (self.panels.items, 0..) |*p, i| {
                p.visible = (i == self.focus_idx);
            }
            self.setStatus("Zoomed active panel (press z to restore)");
        }
    }

    fn togglePanelAt(self: *TuiApp, idx: usize) void {
        if (idx >= self.panels.items.len) return;
        var visible_count: usize = 0;
        for (self.panels.items) |p| {
            if (p.visible) visible_count += 1;
        }
        if (self.panels.items[idx].visible and visible_count <= 1) {
            self.setStatus("At least one panel must remain visible");
            return;
        }
        self.panels.items[idx].visible = !self.panels.items[idx].visible;
        if (!self.panels.items[idx].visible and self.focus_idx == idx) {
            self.cycleFocus(1);
        }
    }

    fn handleLogsKey(self: *TuiApp, key: Key) void {
        switch (key) {
            .up => self.logs_scroll_from_bottom += 1,
            .down => self.logs_scroll_from_bottom -|= 1,
            .page_up => self.logs_scroll_from_bottom += 10,
            .page_down => self.logs_scroll_from_bottom -|= 10,
            .end => self.logs_scroll_from_bottom = 0,
            .char => |cp| {
                if (cp == 'f') {
                    self.logs_only_job_ui = !self.logs_only_job_ui;
                    self.logs_scroll_from_bottom = 0;
                    self.setStatus(if (self.logs_only_job_ui) "Logs: job.*/ui.* only" else "Logs: all telemetry");
                } else if (cp == 'G') {
                    self.logs_scroll_from_bottom = 0;
                }
            },
            else => {},
        }
    }

    pub fn executeActiveCapability(self: *TuiApp, dispatcher: inbound.HostDispatcher) !void {
        const spec = self.state.activeCapability() orelse return;
        if (!self.state.validateForm()) {
            self.setStatus("Validation error: check highlighted fields");
            self.focusKind(.form);
            return;
        }

        const payload_json = try self.state.serializeFormJson(self.alloc);
        defer self.alloc.free(payload_json);

        self.setStatusFmt("Running {s}...", .{spec.id});
        const resp = dispatcher.dispatch(.{
            .command_or_route = spec.id,
            .payload = payload_json,
            .args_json = "{\"custom\":true,\"input\":\"job_json\"}",
        }) catch |err| {
            self.setStatusFmt("Dispatch error: {s}", .{@errorName(err)});
            return;
        };

        if (self.raw_last_body.len > 0) self.alloc.free(self.raw_last_body);
        self.raw_last_body = try self.alloc.dupe(u8, resp.body);

        // Invoke custom RendererVTable if registered for capability_id or mime_type
        for (self.config.custom_renderers) |cr| {
            const match_cap = if (cr.capability_id) |cid| std.mem.eql(u8, cid, spec.id) else false;
            const match_mime = if (cr.mime_type) |mt|
                (spec.output.mime_type != null and std.mem.eql(u8, spec.output.mime_type.?, mt))
            else
                false;
            if (match_cap or match_mime) {
                cr.vtable.render(cr.vtable.ctx, spec.id, resp.body) catch {};
                break;
            }
        }

        try self.state.result.loadResponse(spec, resp.status_code, resp.body);
        self.table_sort_next_col = 0;
        self.setStatusFmt("{s} -> HTTP {d}", .{ spec.id, resp.status_code });
        if (resp.status_code >= 200 and resp.status_code < 300) {
            self.focusKind(.output);
        }
    }

    pub fn render(self: *TuiApp, screen: *Screen) void {
        const w = screen.width;
        const h = screen.height;
        screen.clear(.{});
        if (w < 20 or h < 10) {
            screen.drawText(0, 0, w, "Terminal too small", .{ .fg = .red, .bold = true });
            return;
        }

        // 1. Header bar (row 0)
        const header_style = Style{ .fg = .black, .bg = .cyan, .bold = true };
        screen.fillRect(0, 0, w, 1, ' ', header_style);
        const app_title = self.config.title orelse self.state.catalog.name;
        var hbuf: [128]u8 = undefined;
        const htext = std.fmt.bufPrint(&hbuf, " {s} v{s} ", .{ app_title, self.state.catalog.version }) catch " Parabellum TUI ";
        screen.drawText(0, 0, w, htext, header_style);
        const hint = "1-9:Focus  z:Zoom  Alt+1-9:Toggle  F5:Run  ?:Help  q:Quit ";
        if (w > hint.len + htext.len) {
            screen.drawText(w - @as(u16, @intCast(hint.len)), 0, @intCast(hint.len), hint, header_style);
        }

        // 2. Footer status bar (row h - 1)
        const footer_style = Style{ .fg = .white, .bg = .bright_black };
        screen.fillRect(0, h - 1, w, 1, ' ', footer_style);
        screen.drawText(1, h - 1, w - 2, self.statusSlice(), footer_style);

        const body_h = h - 2;
        const left_count = self.countVisibleInDock(.left);
        const top_count = self.countVisibleInDock(.main_top);
        const bot_count = self.countVisibleInDock(.main_bottom);
        const right_count = self.countVisibleInDock(.right);
        const bottom_count = self.countVisibleInDock(.bottom);

        const has_main = left_count + top_count + bot_count + right_count > 0;
        const bottom_h: u16 = if (bottom_count == 0)
            0
        else if (!has_main)
            body_h
        else if (body_h >= 12)
            @max(5, body_h / 4)
        else
            0;
        const main_h = body_h - bottom_h;

        if (main_h > 0 and has_main) {
            const has_center = (top_count + bot_count) > 0;
            const left_w: u16 = if (left_count == 0)
                0
            else if (!has_center and right_count == 0)
                w
            else
                @min(34, @max(18, w / 4));

            const right_col_w: u16 = if (right_count == 0)
                0
            else if (!has_center)
                w - left_w
            else
                @min(38, @max(20, (w - left_w) / 3));

            const center_w = w - left_w - right_col_w;

            if (left_w > 0) {
                self.renderDockVertical(screen, .left, 0, 1, left_w, main_h);
            }
            if (center_w > 0 and has_center) {
                const top_h: u16 = if (top_count == 0)
                    0
                else if (bot_count == 0)
                    main_h
                else if (self.state.form_fields.items.len == 0 and top_count == 1)
                    4
                else
                    @min(main_h / 2, @as(u16, @intCast(self.state.form_fields.items.len + 4)) * @as(u16, @intCast(top_count)));
                const bot_h = main_h - top_h;
                if (top_h > 0) self.renderDockVertical(screen, .main_top, left_w, 1, center_w, top_h);
                if (bot_h > 0) self.renderDockVertical(screen, .main_bottom, left_w, 1 + top_h, center_w, bot_h);
            }
            if (right_col_w > 0) {
                self.renderDockVertical(screen, .right, left_w + center_w, 1, right_col_w, main_h);
            }
        }

        // 5. Bottom dock (Telemetry Logs + any custom bottom panels)
        if (bottom_h > 0) {
            self.renderDockHorizontal(screen, .bottom, 0, 1 + main_h, w, bottom_h);
        }

        // 6. Modals
        switch (self.modal) {
            .none => {},
            .palette => self.renderPaletteModal(screen),
            .help => self.renderHelpModal(screen),
            .actions => self.renderActionsModal(screen),
        }
    }

    fn countVisibleInDock(self: *const TuiApp, dock: PanelDock) usize {
        var n: usize = 0;
        for (self.panels.items) |p| {
            if (p.visible and p.dock == dock) n += 1;
        }
        return n;
    }

    fn renderDockVertical(self: *TuiApp, screen: *Screen, dock: PanelDock, x: u16, y: u16, w: u16, h: u16) void {
        const count = self.countVisibleInDock(dock);
        if (count == 0 or w == 0 or h == 0) return;
        const base_h = h / @as(u16, @intCast(count));
        var cur_y = y;
        var seen: usize = 0;
        for (self.panels.items, 0..) |p, idx| {
            if (!p.visible or p.dock != dock) continue;
            seen += 1;
            const ph = if (seen == count) (y + h) - cur_y else base_h;
            self.renderPanel(idx, screen, x, cur_y, w, ph);
            cur_y += ph;
        }
    }

    fn renderDockHorizontal(self: *TuiApp, screen: *Screen, dock: PanelDock, x: u16, y: u16, w: u16, h: u16) void {
        const count = self.countVisibleInDock(dock);
        if (count == 0 or w == 0 or h == 0) return;
        const base_w = w / @as(u16, @intCast(count));
        var cur_x = x;
        var seen: usize = 0;
        for (self.panels.items, 0..) |p, idx| {
            if (!p.visible or p.dock != dock) continue;
            seen += 1;
            const pw = if (seen == count) (x + w) - cur_x else base_w;
            self.renderPanel(idx, screen, cur_x, y, pw, h);
            cur_x += pw;
        }
    }

    fn renderPanel(self: *TuiApp, idx: usize, screen: *Screen, x: u16, y: u16, w: u16, h: u16) void {
        const p = self.panels.items[idx];
        const focused = self.focus_idx == idx;
        var tbuf: [96]u8 = undefined;
        const numbered_title = std.fmt.bufPrint(&tbuf, "[{d}] {s}", .{ idx + 1, p.title }) catch p.title;
        switch (p.kind) {
            .sidebar => self.renderSidebar(screen, x, y, w, h, focused, numbered_title),
            .form => self.renderForm(screen, x, y, w, h, focused, numbered_title),
            .output => self.renderOutput(screen, x, y, w, h, focused, numbered_title),
            .logs => self.renderLogs(screen, x, y, w, h, focused, numbered_title),
            .custom => {
                screen.drawBox(x, y, w, h, numbered_title, focused, .{});
                if (w >= 4 and h >= 3) {
                    if (p.custom) |cp| {
                        const surf = PanelSurface{
                            .screen = screen,
                            .x = x + 1,
                            .y = y + 1,
                            .width = w - 2,
                            .height = h - 2,
                        };
                        cp.render(cp.ctx, surf, focused);
                    }
                }
            },
        }
    }

    fn renderSidebar(self: *const TuiApp, screen: *Screen, x: u16, y: u16, w: u16, h: u16, focused: bool, panel_title: []const u8) void {
        screen.drawBox(x, y, w, h, panel_title, focused, .{});
        if (w < 4 or h < 3) return;
        const inner_h = h - 2;
        const inner_w = w - 2;

        const items = self.state.sidebar_items.items;
        const start: usize = if (self.state.selected_sidebar >= inner_h)
            self.state.selected_sidebar - inner_h + 1
        else
            0;

        var row: u16 = 0;
        while (row < inner_h and start + row < items.len) : (row += 1) {
            const idx = start + row;
            const it = items[idx];
            const ry = y + 1 + row;
            if (it.is_group) {
                screen.drawText(x + 1, ry, inner_w, it.group_name, .{ .fg = .yellow, .bold = true });
            } else {
                const spec = self.state.catalog.capabilities[it.cap_index];
                const selected = idx == self.state.selected_sidebar;
                const active = self.state.active_cap_idx != null and self.state.active_cap_idx.? == it.cap_index;
                const st = Style{
                    .fg = if (selected) .black else if (active) .bright_green else .white,
                    .bg = if (selected) .cyan else .default,
                    .bold = selected or active,
                };
                if (selected) screen.fillRect(x + 1, ry, inner_w, 1, ' ', st);
                var line_buf: [64]u8 = undefined;
                const label = spec.title orelse spec.id;
                const line = std.fmt.bufPrint(&line_buf, "  {s}", .{label}) catch label;
                screen.drawText(x + 1, ry, inner_w, line, st);
            }
        }
    }

    fn renderForm(self: *const TuiApp, screen: *Screen, x: u16, y: u16, w: u16, h: u16, focused: bool, panel_title: []const u8) void {
        const spec = self.state.activeCapability();
        var tbuf: [96]u8 = undefined;
        const title = if (spec) |s|
            (std.fmt.bufPrint(&tbuf, "{s}: {s}", .{ panel_title, s.title orelse s.id }) catch panel_title)
        else
            panel_title;
        screen.drawBox(x, y, w, h, title, focused, .{});
        if (w < 6 or h < 3) return;
        const inner_w = w - 2;
        const inner_h = h - 2;

        if (spec == null) return;

        var row: u16 = 0;
        var mask_buf: [64]u8 = undefined;
        for (self.state.form_fields.items, 0..) |f, idx| {
            if (row + 1 >= inner_h) break;
            const ry = y + 1 + row;
            const is_sel = focused and self.state.active_field_idx == idx;
            const label = f.spec.label orelse f.spec.name;
            const val = f.displayValue(&mask_buf);

            var lbuf: [160]u8 = undefined;
            const req_mark: []const u8 = if (f.spec.required) "*" else " ";
            const err_part: []const u8 = f.err_msg orelse "";
            const path_hint: []const u8 = if (is_sel and (f.spec.field_type == .file_path or f.spec.field_type == .dir_path))
                " (Right: complete)"
            else
                "";
            const line = if (err_part.len > 0)
                std.fmt.bufPrint(&lbuf, "{s}{s}: [{s}] ! {s}", .{ req_mark, label, val, err_part }) catch label
            else
                std.fmt.bufPrint(&lbuf, "{s}{s}: [{s}]{s}", .{ req_mark, label, val, path_hint }) catch label;

            const st = Style{
                .fg = if (f.err_msg != null) .red else if (is_sel) .black else .white,
                .bg = if (is_sel) .cyan else .default,
                .bold = is_sel,
            };
            if (is_sel) screen.fillRect(x + 1, ry, inner_w, 1, ' ', st);
            screen.drawText(x + 1, ry, inner_w, line, st);
            row += 1;
        }

        // Run button
        if (row < inner_h) {
            const ry = y + 1 + row;
            const on_btn = focused and self.state.active_field_idx >= self.state.form_fields.items.len;
            const btn_st = Style{
                .fg = if (on_btn) .black else .bright_green,
                .bg = if (on_btn) .green else .default,
                .bold = true,
            };
            screen.drawText(x + 2, ry, inner_w -| 1, "[ Run (F5) ]", btn_st);
        }
    }

    fn renderOutput(self: *const TuiApp, screen: *Screen, x: u16, y: u16, w: u16, h: u16, focused: bool, panel_title: []const u8) void {
        var title_buf: [96]u8 = undefined;
        const back_hint: []const u8 = if (self.nav_history.items.len > 0) " | Backspace/b: Back" else "";
        const title = switch (self.state.result.kind) {
            .empty => panel_title,
            else => std.fmt.bufPrint(&title_buf, "{s} ({s}{s})", .{ panel_title, @tagName(self.state.result.kind), back_hint }) catch panel_title,
        };
        screen.drawBox(x, y, w, h, title, focused, .{});
        if (w < 6 or h < 3) return;
        const ix = x + 1;
        const iy = y + 1;
        const iw = w - 2;
        const ih = h - 2;

        const res = &self.state.result;
        switch (res.kind) {
            .empty => screen.drawText(ix, iy, iw, "Select a capability and press F5 or Run.", .{ .dim = true }),
            .scalar => screen.drawText(ix, iy, iw, res.scalar_text, .{ .fg = .bright_white }),
            .media_blob => {
                var mbuf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&mbuf, "[media_blob: {s}, {d} bytes]", .{ res.media_mime, res.media_bytes_len }) catch "[media_blob]";
                screen.drawText(ix, iy, iw, msg, .{ .fg = .yellow });
            },
            .log_stream => screen.drawText(ix, iy, iw, "Streaming output in Telemetry Logs panel below.", .{ .fg = .cyan }),
            .record => {
                const start = visibleStart(res.selected_idx, res.record_fields.len, ih);
                var r: u16 = 0;
                while (r < ih and start + r < res.record_fields.len) : (r += 1) {
                    const idx = start + r;
                    const kv = res.record_fields[idx];
                    const sel = focused and idx == res.selected_idx;
                    const st = Style{ .fg = if (sel) .black else .white, .bg = if (sel) .cyan else .default };
                    if (sel) screen.fillRect(ix, iy + r, iw, 1, ' ', st);
                    var lbuf: [256]u8 = undefined;
                    const line = std.fmt.bufPrint(&lbuf, "{s}: {s}", .{ kv.key, kv.value }) catch kv.key;
                    screen.drawText(ix, iy + r, iw, line, st);
                }
            },
            .table => {
                if (res.table_cols.len == 0 or res.table_rows.len == 0) {
                    screen.drawText(ix, iy, iw, "(empty)", .{ .dim = true });
                    return;
                }
                const col_w: u16 = @max(6, iw / @as(u16, @intCast(res.table_cols.len)));
                for (res.table_cols, 0..) |col_name, ci| {
                    const cx = ix + @as(u16, @intCast(ci)) * col_w;
                    if (cx >= ix + iw) break;
                    screen.drawText(cx, iy, @min(col_w - 1, ix + iw - cx), col_name, .{ .fg = .yellow, .bold = true });
                }
                const data_h = ih -| 1;
                const start = visibleStart(res.selected_idx, res.table_rows.len, data_h);
                var r: u16 = 0;
                while (r < data_h and start + r < res.table_rows.len) : (r += 1) {
                    const idx = start + r;
                    const row = res.table_rows[idx];
                    const sel = focused and idx == res.selected_idx;
                    const st = Style{ .fg = if (sel) .black else .white, .bg = if (sel) .cyan else .default };
                    if (sel) screen.fillRect(ix, iy + 1 + r, iw, 1, ' ', st);
                    for (row, 0..) |cell_val, ci| {
                        const cx = ix + @as(u16, @intCast(ci)) * col_w;
                        if (cx >= ix + iw) break;
                        screen.drawText(cx, iy + 1 + r, @min(col_w - 1, ix + iw - cx), cell_val, st);
                    }
                }
            },
            .tree => {
                const start = visibleStart(res.selected_idx, res.tree_flat.items.len, ih);
                var r: u16 = 0;
                while (r < ih and start + r < res.tree_flat.items.len) : (r += 1) {
                    const idx = start + r;
                    const node = res.tree_flat.items[idx];
                    const sel = focused and idx == res.selected_idx;
                    const st = Style{ .fg = if (sel) .black else .white, .bg = if (sel) .cyan else .default };
                    if (sel) screen.fillRect(ix, iy + r, iw, 1, ' ', st);
                    const indent = @min(iw / 2, node.depth * 2);
                    const glyph: []const u8 = if (!node.has_children) "  " else if (node.expanded) "▾ " else "▸ ";
                    var lbuf: [160]u8 = undefined;
                    const line = std.fmt.bufPrint(&lbuf, "{s}{s}", .{ glyph, node.label }) catch node.label;
                    screen.drawText(ix + indent, iy + r, iw - indent, line, st);
                }
            },
            .document => {
                const start = visibleStart(res.selected_idx, res.doc_lines.len, ih);
                var r: u16 = 0;
                while (r < ih and start + r < res.doc_lines.len) : (r += 1) {
                    const idx = start + r;
                    const sel = focused and idx == res.selected_idx;
                    const st = Style{ .fg = if (sel) .black else .white, .bg = if (sel) .cyan else .default };
                    if (sel) screen.fillRect(ix, iy + r, iw, 1, ' ', st);
                    screen.drawText(ix, iy + r, iw, res.doc_lines[idx], st);
                }
            },
        }
    }

    fn renderLogs(self: *TuiApp, screen: *Screen, x: u16, y: u16, w: u16, h: u16, focused: bool, panel_title: []const u8) void {
        if (w < 4 or h < 3) {
            screen.drawBox(x, y, w, h, panel_title, focused, .{});
            return;
        }
        const ih = h - 2;
        const iw = w - 2;

        var entries: [EventRing.CAPACITY]LogEntry = undefined;
        const total = self.ring.snapshotRecent(&entries, self.logs_only_job_ui);
        const max_scroll = total -| ih;
        if (self.logs_scroll_from_bottom > max_scroll) {
            self.logs_scroll_from_bottom = max_scroll;
        }
        const end = total -| self.logs_scroll_from_bottom;
        const start = end -| ih;

        const stats = self.ring.stats();
        var tbuf: [112]u8 = undefined;
        const mode = if (self.logs_only_job_ui) "job/ui" else "all";
        const title = if (self.logs_scroll_from_bottom > 0)
            std.fmt.bufPrint(&tbuf, "{s} [{s} -{d}] (dropped:{d})", .{ panel_title, mode, self.logs_scroll_from_bottom, stats.dropped }) catch panel_title
        else
            std.fmt.bufPrint(&tbuf, "{s} [{s} tail] (dropped:{d})", .{ panel_title, mode, stats.dropped }) catch panel_title;
        screen.drawBox(x, y, w, h, title, focused, .{});

        var line_buf: [256]u8 = undefined;
        var r: u16 = 0;
        while (r < ih and start + r < end) : (r += 1) {
            const entry = entries[start + r];
            const line = entry.formatLine(&line_buf);
            const fg: term.Color = switch (entry.kind) {
                .job_failed => .red,
                .job_completed => .green,
                .job_progress, .job_started => .cyan,
                else => .white,
            };
            screen.drawText(x + 1, y + 1 + r, iw, line, .{ .fg = fg });
        }
    }

    fn renderPaletteModal(self: *const TuiApp, screen: *Screen) void {
        const mw: u16 = @min(50, screen.width -| 4);
        const mh: u16 = 5;
        const mx: u16 = (screen.width - mw) / 2;
        const my: u16 = 2;
        screen.drawBox(mx, my, mw, mh, "Command Palette (Filter)", true, .{ .bg = .black });
        screen.drawText(mx + 2, my + 2, mw - 4, self.palette_query.items, .{ .fg = .bright_yellow, .bg = .black });
    }

    fn renderHelpModal(self: *const TuiApp, screen: *Screen) void {
        const mw: u16 = @min(60, screen.width -| 4);
        const mh: u16 = @min(14, screen.height -| 4);
        const mx: u16 = (screen.width - mw) / 2;
        const my: u16 = (screen.height - mh) / 2;
        screen.drawBox(mx, my, mw, mh, "Keybindings (? to close)", true, .{ .bg = .black });
        const lines = [_][]const u8{
            "1-9 / Tab       : Focus panel directly / cycle",
            "z / Alt+1-9     : Zoom active panel / toggle panel",
            "Up / Down       : Navigate / scroll logs",
            "Enter / F5      : Select / Run capability",
            "Space / L / R   : Toggle bool / enum / tree node",
            "s (in table)    : Sort by next column",
            "a / Enter (out) : Open / run contextual ActionLinks",
            "Backspace / b   : Go back (previous view / parent dir)",
            ": or /          : Filter capabilities",
            "f / G (in logs) : Filter job/ui vs all / Jump to tail",
            "q / Ctrl+Q      : Quit",
        };
        for (lines, 0..) |l, i| {
            if (i + 2 >= mh) break;
            screen.drawText(mx + 2, my + 1 + @as(u16, @intCast(i)), mw - 4, l, .{ .fg = .white, .bg = .black });
        }
        var row: usize = lines.len;
        for (self.config.keymap) |km| {
            if (row + 2 >= mh) break;
            var kbuf: [64]u8 = undefined;
            const kline = std.fmt.bufPrint(&kbuf, "{s} : {s} ({s})", .{ km.key, km.capability_id, km.description }) catch km.capability_id;
            screen.drawText(mx + 2, my + 1 + @as(u16, @intCast(row)), mw - 4, kline, .{ .fg = .bright_cyan, .bg = .black });
            row += 1;
        }
    }

    fn renderActionsModal(self: *const TuiApp, screen: *Screen) void {
        const mw: u16 = @min(44, screen.width -| 4);
        const mh: u16 = @min(10, @as(u16, @intCast(self.action_count + 3)));
        const mx: u16 = (screen.width - mw) / 2;
        const my: u16 = (screen.height - mh) / 2;
        screen.drawBox(mx, my, mw, mh, "Contextual Actions", true, .{ .bg = .black });
        for (0..self.action_count) |i| {
            if (i + 2 >= mh) break;
            const sel = i == self.action_selected;
            const st = Style{ .fg = if (sel) .black else .white, .bg = if (sel) .cyan else .black };
            if (sel) screen.fillRect(mx + 1, my + 1 + @as(u16, @intCast(i)), mw - 2, 1, ' ', st);
            screen.drawText(mx + 2, my + 1 + @as(u16, @intCast(i)), mw - 4, self.action_choices[i].label, st);
        }
    }

    fn visibleStart(selected: usize, total: usize, height: u16) usize {
        if (height == 0 or total <= height) return 0;
        if (selected >= height) return selected - height + 1;
        return 0;
    }
};

test "TuiApp renders catalog, executes capability via HostDispatcher, and updates OutputView" {
    const alloc = std.testing.allocator;
    const catalog = cap.CapabilityCatalog{
        .id = "test_app",
        .name = "TestApp",
        .version = "1.0.0",
        .capabilities = &.{
            .{
                .id = "sys.info",
                .group = "system",
                .title = "System Info",
                .output = .{ .kind = .record },
            },
        },
    };

    const MockHost = struct {
        fn dispatch(_: *anyopaque, _: *const abi.InboundRequest_ABI, out_resp: *abi.InboundResponse_ABI) callconv(.c) abi.HostError_ABI {
            out_resp.* = .{
                .status_code = 200,
                .body = abi.Slice_ABI.from("{\"fields\":[{\"key\":\"status\",\"value\":\"healthy\"}]}"),
            };
            return .ok;
        }
    };

    var dummy_ctx: u8 = 0;
    const dispatcher = inbound.HostDispatcher{
        .ptr = @ptrCast(&dummy_ctx),
        .dispatch_fn = MockHost.dispatch,
    };

    var ring = EventRing{};
    var app = try TuiApp.init(alloc, catalog, &ring, .{});
    defer app.deinit();

    var scr = Screen.init(alloc);
    defer scr.deinit();
    try scr.resize(80, 24);

    try app.handleKey(.f5, dispatcher);
    try std.testing.expectEqual(ResultKind.record, app.state.result.kind);
    try std.testing.expectEqual(PanelKind.output, app.focusedPanelKind());

    app.render(&scr);
    try std.testing.expectEqualStrings("sys.info -> HTTP 200", app.statusSlice());

    // Focus panels 1-4 directly and test zoom ('z') + Alt+toggle without crashing
    try app.handleKey(.{ .char = '3' }, dispatcher);
    try std.testing.expectEqual(PanelKind.output, app.focusedPanelKind());
    try app.handleKey(.{ .char = 'z' }, dispatcher);
    app.render(&scr);
    try app.handleKey(.{ .char = 'z' }, dispatcher);
    app.render(&scr);
    try app.handleKey(.{ .alt_char = '1' }, dispatcher);
    app.render(&scr);
    try app.handleKey(.{ .char = '1' }, dispatcher);
    app.render(&scr);
}

test "TuiApp supports extensible custom panels via Config.extra_panels" {
    const alloc = std.testing.allocator;
    const CustomState = struct {
        rendered: bool = false,
        key_hits: usize = 0,
        fn onRender(ctx: ?*anyopaque, surface: PanelSurface, _: bool) void {
            const st: *@This() = @ptrCast(@alignCast(ctx.?));
            st.rendered = true;
            surface.drawText(0, 0, surface.width, "Custom Metrics", .{});
        }
        fn onKey(ctx: ?*anyopaque, _: Key, _: inbound.HostDispatcher) !bool {
            const st: *@This() = @ptrCast(@alignCast(ctx.?));
            st.key_hits += 1;
            return true;
        }
    };
    var custom_st = CustomState{};

    const catalog = cap.CapabilityCatalog{
        .id = "ext_app",
        .name = "ExtApp",
    };
    const MockHost = struct {
        fn dispatch(_: *anyopaque, _: *const abi.InboundRequest_ABI, out_resp: *abi.InboundResponse_ABI) callconv(.c) abi.HostError_ABI {
            out_resp.* = .{ .status_code = 200, .body = abi.Slice_ABI.empty };
            return .ok;
        }
    };
    var dummy_ctx: u8 = 0;
    const dispatcher = inbound.HostDispatcher{ .ptr = @ptrCast(&dummy_ctx), .dispatch_fn = MockHost.dispatch };

    var ring = EventRing{};
    var app = try TuiApp.init(alloc, catalog, &ring, .{
        .extra_panels = &.{
            .{
                .id = "metrics",
                .title = "Metrics",
                .dock = .right,
                .ctx = &custom_st,
                .render = CustomState.onRender,
                .handle_key = CustomState.onKey,
            },
        },
    });
    defer app.deinit();

    var scr = Screen.init(alloc);
    defer scr.deinit();
    try scr.resize(100, 30);

    app.render(&scr);
    try std.testing.expect(custom_st.rendered);
    try std.testing.expectEqual(@as(usize, 5), app.panels.items.len);

    // Cycle focus to the 5th panel (custom) and send a key
    try app.handleKey(.back_tab, dispatcher);
    try std.testing.expectEqual(PanelKind.custom, app.focusedPanelKind());
    try app.handleKey(.{ .char = 'r' }, dispatcher);
    try std.testing.expectEqual(@as(usize, 1), custom_st.key_hits);

    // Toggle 5th panel off with Alt+5
    try app.handleKey(.{ .alt_char = '5' }, dispatcher);
    try std.testing.expect(!app.panels.items[4].visible);
}
