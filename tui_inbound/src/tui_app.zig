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
    preferred_height: u16 = 0,
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
    show_sidebar: bool = true,
    show_menubar: bool = true,
    form_on_demand: bool = false,
    show_logs: bool = true,
    logs_visible: bool = true,
    on_start: ?*const fn (ctx: ?*anyopaque, app: *TuiApp, dispatcher: inbound.HostDispatcher) void = null,
    on_start_ctx: ?*anyopaque = null,
    on_tick: ?*const fn (ctx: ?*anyopaque, app: *TuiApp, dispatcher: inbound.HostDispatcher) void = null,
    on_tick_ctx: ?*anyopaque = null,
    on_capability_complete: ?*const fn (ctx: ?*anyopaque, app: *TuiApp, cap_id: []const u8, status_code: i32, dispatcher: inbound.HostDispatcher) void = null,
    on_capability_complete_ctx: ?*anyopaque = null,
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
    collapsed: bool = false,
    preferred_height: u16 = 0,
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
    menubar_focused: bool = false,

    palette_query: std.ArrayList(u8) = .empty,
    action_choices: [8]cap.ActionLink = undefined,
    action_count: usize = 0,
    action_selected: usize = 0,

    table_sort_next_col: usize = 0,
    path_complete_cycle: usize = 0,
    status_msg: [128]u8 = undefined,
    status_len: usize = 0,
    raw_last_body: []u8 = &.{},

    dispatch_mu: SpinMutex = .{},
    dispatch_in_flight: bool = false,
    dispatch_thread: ?std.Thread = null,
    pending_dispatch_result: ?PendingDispatchResult = null,

    const SpinMutex = struct {
        locked: std.atomic.Value(bool) = .init(false),

        fn lock(self: *SpinMutex) void {
            while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
                std.Thread.yield() catch {};
            }
        }

        fn unlock(self: *SpinMutex) void {
            self.locked.store(false, .release);
        }
    };

    const PendingDispatchResult = struct {
        spec_id: []u8,
        status_code: i32 = 0,
        body: []u8 = &.{},
        err_name: ?[]const u8 = null,

        fn deinit(self: *PendingDispatchResult, alloc: Allocator) void {
            alloc.free(self.spec_id);
            if (self.body.len > 0) alloc.free(self.body);
        }
    };

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
        if (config.show_sidebar) {
            try app.panels.append(alloc, .{ .id = "capabilities", .title = "Capabilities", .dock = .left, .kind = .sidebar, .visible = true });
        } else {
            for (config.extra_panels) |ep| {
                if (ep.dock == .left) {
                    try app.panels.append(alloc, .{
                        .id = ep.id,
                        .title = ep.title,
                        .dock = ep.dock,
                        .kind = .custom,
                        .visible = ep.visible,
                        .preferred_height = ep.preferred_height,
                        .custom = ep,
                    });
                }
            }
        }
        try app.panels.appendSlice(alloc, &.{
            .{ .id = "form", .title = "Form", .dock = .main_top, .kind = .form, .visible = !config.form_on_demand },
            .{ .id = "output", .title = "Output", .dock = .main_bottom, .kind = .output, .visible = true },
        });
        if (config.show_logs) {
            try app.panels.append(alloc, .{
                .id = "logs",
                .title = "Telemetry Logs",
                .dock = .bottom,
                .kind = .logs,
                .visible = true,
                .collapsed = !config.logs_visible,
            });
        }
        for (config.extra_panels) |ep| {
            if (!config.show_sidebar and ep.dock == .left) continue;
            try app.panels.append(alloc, .{
                .id = ep.id,
                .title = ep.title,
                .dock = ep.dock,
                .kind = .custom,
                .visible = ep.visible,
                .preferred_height = ep.preferred_height,
                .custom = ep,
            });
        }
        // Focus the first visible panel
        for (app.panels.items, 0..) |p, idx| {
            if (p.visible) {
                app.focus_idx = idx;
                break;
            }
        }
        app.setStatus("Ready. m:Menu | 1-9:Focus | z:Zoom | a:Actions | F5:Run | ?:Help | q:Quit");
        return app;
    }

    pub fn deinit(self: *TuiApp) void {
        if (self.dispatch_thread) |t| {
            t.join();
            self.dispatch_thread = null;
        }
        if (self.pending_dispatch_result) |*pdr| {
            pdr.deinit(self.alloc);
            self.pending_dispatch_result = null;
        }
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

    pub fn focusedPanelKind(self: *const TuiApp) PanelKind {
        if (self.focus_idx < self.panels.items.len) {
            return self.panels.items[self.focus_idx].kind;
        }
        return .sidebar;
    }

    pub fn hideFormPanel(self: *TuiApp) void {
        if (!self.form_on_demand()) return;
        for (self.panels.items) |*p| {
            if (p.kind == .form) {
                p.visible = false;
                return;
            }
        }
    }

    fn form_on_demand(self: *const TuiApp) bool {
        return self.config.form_on_demand;
    }

    pub fn setPanelVisible(self: *TuiApp, id: []const u8, visible: bool) void {
        for (self.panels.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) {
                p.visible = visible;
                return;
            }
        }
    }

    pub fn focusPanelById(self: *TuiApp, id: []const u8) void {
        for (self.panels.items, 0..) |*p, idx| {
            if (std.mem.eql(u8, p.id, id)) {
                p.visible = true;
                self.focus_idx = idx;
                return;
            }
        }
    }

    pub fn openCapabilityForm(
        self: *TuiApp,
        cap_id: []const u8,
        prefill: []const struct { name: []const u8, value: []const u8 },
    ) !void {
        if (!try self.state.selectCapabilityById(cap_id)) return;
        for (prefill) |kv| {
            for (self.state.form_fields.items) |*f| {
                if (std.mem.eql(u8, f.spec.name, kv.name)) {
                    try f.setValue(self.alloc, kv.value);
                }
            }
        }
        self.focusKind(.form);
    }

    pub fn dispatchCapabilityToOutput(
        self: *TuiApp,
        cap_id: []const u8,
        payload_json: []const u8,
        dispatcher: inbound.HostDispatcher,
    ) !void {
        if (!try self.state.selectCapabilityById(cap_id)) return;
        const spec = self.state.activeCapability() orelse return;
        try self.dispatchSpec(spec, payload_json, dispatcher);
    }

    fn dispatchSpec(
        self: *TuiApp,
        spec: cap.CapabilitySpec,
        payload_json: []const u8,
        dispatcher: inbound.HostDispatcher,
    ) !void {
        if (self.ring.wakeup_fd != null) {
            self.startAsyncDispatch(spec.id, payload_json, dispatcher);
            return;
        }
        self.setStatusFmt("Running {s}...", .{spec.id});
        const resp = dispatcher.dispatch(.{
            .command_or_route = spec.id,
            .payload = payload_json,
            .args_json = "{\"custom\":true,\"input\":\"job_json\"}",
        }) catch |err| {
            self.setStatusFmt("Dispatch error: {s}", .{@errorName(err)});
            return;
        };
        try self.applyDispatchResponse(spec, resp.status_code, resp.body, dispatcher);
    }

    fn startAsyncDispatch(
        self: *TuiApp,
        spec_id: []const u8,
        payload_json: []const u8,
        dispatcher: inbound.HostDispatcher,
    ) void {
        self.dispatch_mu.lock();
        if (self.dispatch_in_flight) {
            self.dispatch_mu.unlock();
            self.setStatus("A job is already running...");
            return;
        }
        self.dispatch_in_flight = true;
        self.dispatch_mu.unlock();

        if (self.dispatch_thread) |prev| {
            prev.join();
            self.dispatch_thread = null;
        }

        const owned_spec_id = self.alloc.dupe(u8, spec_id) catch {
            self.dispatch_mu.lock();
            self.dispatch_in_flight = false;
            self.dispatch_mu.unlock();
            self.setStatus("Out of memory starting dispatch");
            return;
        };
        const owned_payload = self.alloc.dupe(u8, payload_json) catch {
            self.alloc.free(owned_spec_id);
            self.dispatch_mu.lock();
            self.dispatch_in_flight = false;
            self.dispatch_mu.unlock();
            self.setStatus("Out of memory starting dispatch");
            return;
        };

        self.setStatusFmt("Running {s}...", .{spec_id});
        const t = std.Thread.spawn(.{}, dispatchWorkerThread, .{ self, owned_spec_id, owned_payload, dispatcher }) catch {
            self.alloc.free(owned_spec_id);
            self.alloc.free(owned_payload);
            self.dispatch_mu.lock();
            self.dispatch_in_flight = false;
            self.dispatch_mu.unlock();
            self.setStatus("Failed to spawn worker thread");
            return;
        };
        self.dispatch_thread = t;
    }

    fn dispatchWorkerThread(
        self: *TuiApp,
        owned_spec_id: []u8,
        owned_payload: []u8,
        dispatcher: inbound.HostDispatcher,
    ) void {
        defer self.alloc.free(owned_payload);

        var result = PendingDispatchResult{
            .spec_id = owned_spec_id,
        };
        if (dispatcher.dispatch(.{
            .command_or_route = owned_spec_id,
            .payload = owned_payload,
            .args_json = "{\"custom\":true,\"input\":\"job_json\"}",
        })) |resp| {
            result.status_code = resp.status_code;
            result.body = self.alloc.dupe(u8, resp.body) catch &.{};
        } else |err| {
            result.err_name = @errorName(err);
        }

        self.dispatch_mu.lock();
        if (self.pending_dispatch_result) |*old| {
            old.deinit(self.alloc);
        }
        self.pending_dispatch_result = result;
        self.dispatch_in_flight = false;
        self.dispatch_mu.unlock();

        if (self.ring.wakeup_fd) |wfd| {
            const b = [1]u8{1};
            _ = std.c.write(wfd, &b, 1);
        }
    }

    fn pollCompletedDispatch(self: *TuiApp, dispatcher: inbound.HostDispatcher) !void {
        self.dispatch_mu.lock();
        const maybe_res = self.pending_dispatch_result;
        self.pending_dispatch_result = null;
        self.dispatch_mu.unlock();

        var res = maybe_res orelse return;
        defer res.deinit(self.alloc);

        if (self.dispatch_thread) |t| {
            t.join();
            self.dispatch_thread = null;
        }

        if (res.err_name) |ename| {
            self.setStatusFmt("Dispatch error: {s}", .{ename});
            return;
        }

        if (!try self.state.selectCapabilityById(res.spec_id)) return;
        const spec = self.state.activeCapability() orelse return;
        try self.applyDispatchResponse(spec, res.status_code, res.body, dispatcher);
    }

    fn applyDispatchResponse(
        self: *TuiApp,
        spec: cap.CapabilitySpec,
        status_code: i32,
        body: []const u8,
        dispatcher: inbound.HostDispatcher,
    ) !void {
        if (self.raw_last_body.len > 0) self.alloc.free(self.raw_last_body);
        self.raw_last_body = try self.alloc.dupe(u8, body);

        for (self.config.custom_renderers) |cr| {
            const match_cap = if (cr.capability_id) |cid| std.mem.eql(u8, cid, spec.id) else false;
            const match_mime = if (cr.mime_type) |mt|
                (spec.output.mime_type != null and std.mem.eql(u8, spec.output.mime_type.?, mt))
            else
                false;
            if (match_cap or match_mime) {
                cr.vtable.render(cr.vtable.ctx, spec.id, body) catch {};
                break;
            }
        }

        try self.state.result.loadResponse(spec, status_code, body);
        self.table_sort_next_col = 0;
        self.setStatusFmt("{s} -> HTTP {d}", .{ spec.id, status_code });
        if (status_code >= 200 and status_code < 300) {
            self.hideFormPanel();
            self.focusKind(.output);
        }
        if (self.config.on_capability_complete) |cb| {
            cb(self.config.on_capability_complete_ctx, self, spec.id, status_code, dispatcher);
        }
    }

    fn focusKind(self: *TuiApp, kind: PanelKind) void {
        for (self.panels.items, 0..) |*p, idx| {
            if (p.kind == kind) {
                if (p.visible or kind == .form) {
                    p.visible = true;
                    self.focus_idx = idx;
                    return;
                }
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

    pub fn setStatusFmt(self: *TuiApp, comptime fmt: []const u8, args: anytype) void {
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

        self.runStartupCapabilities(dispatcher);
        if (self.config.on_start) |cb| {
            cb(self.config.on_start_ctx, self, dispatcher);
        }

        while (!self.should_quit) {
            try self.pollCompletedDispatch(dispatcher);
            if (self.config.on_tick) |cb| {
                cb(self.config.on_tick_ctx, self, dispatcher);
            }
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
                if (tty.saved_stderr_fd) |saved_fd| {
                    if (std.c.isatty(saved_fd) == 0) {
                        _ = std.c.write(saved_fd, stderr_buf[0..poll_res.stderr_len].ptr, poll_res.stderr_len);
                    }
                }
                var it = std.mem.splitScalar(u8, stderr_buf[0..poll_res.stderr_len], '\n');
                while (it.next()) |line| {
                    const clean = std.mem.trim(u8, line, "\r ");
                    if (clean.len == 0) continue;
                    // Only surface engine errors/warnings in the TUI panel; info/debug go to engine.log
                    if (!std.mem.startsWith(u8, clean, "error:") and !std.mem.startsWith(u8, clean, "warn:")) continue;
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

        // Menubar focus mode
        if (self.menubar_focused) {
            switch (key) {
                .escape => {
                    self.menubar_focused = false;
                    self.setStatus("Menu closed");
                    return;
                },
                .left, .back_tab => {
                    self.moveSidebar(-1);
                    return;
                },
                .right, .tab => {
                    self.moveSidebar(1);
                    return;
                },
                .enter => {
                    self.menubar_focused = false;
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
                    return;
                },
                .char => |cp| {
                    if (cp == 'h') {
                        self.moveSidebar(-1);
                        return;
                    } else if (cp == 'l') {
                        self.moveSidebar(1);
                        return;
                    } else if (cp == 'm' or cp == 'q') {
                        self.menubar_focused = false;
                        return;
                    }
                },
                else => {},
            }
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
                for (self.panels.items, 0..) |*p, idx| {
                    if (p.kind == .logs) {
                        if (!p.visible) {
                            p.visible = true;
                            p.collapsed = false;
                            self.focus_idx = idx;
                        } else {
                            p.collapsed = !p.collapsed;
                            if (!p.collapsed) {
                                self.focus_idx = idx;
                            } else if (self.focus_idx == idx) {
                                self.cycleFocus(1);
                            }
                        }
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
                    if (cp == 'm') {
                        self.menubar_focused = !self.menubar_focused;
                        self.setStatus(if (self.menubar_focused) "Menubar: Left/Right to choose, Enter to select, Esc to close" else "Menu closed");
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
                            self.panels.items[idx].collapsed = false;
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
            .escape => {
                self.hideFormPanel();
                self.focusKind(.output);
                self.setStatus("Form closed");
            },
            .up => {
                if (self.state.active_field_idx > 0) self.state.active_field_idx -= 1;
            },
            .down => {
                try self.maybePrefillNameFromFilePath(self.state.active_field_idx);
                if (self.state.active_field_idx + 1 < total_rows) self.state.active_field_idx += 1;
            },
            .enter => {
                if (self.state.active_field_idx >= self.state.form_fields.items.len) {
                    try self.executeActiveCapability(dispatcher);
                } else {
                    try self.maybePrefillNameFromFilePath(self.state.active_field_idx);
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
                            try self.maybePrefillNameFromFilePath(self.state.active_field_idx);
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

    fn maybePrefillNameFromFilePath(self: *TuiApp, field_idx: usize) !void {
        if (field_idx >= self.state.form_fields.items.len) return;
        const src = &self.state.form_fields.items[field_idx];
        if (src.spec.field_type != .file_path) return;
        const val = src.buf.items;
        if (val.len == 0 or val[val.len - 1] == '/') return;
        const base = std.fs.path.basename(val);
        if (base.len == 0) return;
        for (self.state.form_fields.items) |*dst| {
            if (dst.spec.field_type == .text and std.mem.eql(u8, dst.spec.name, "name") and dst.buf.items.len == 0) {
                try dst.setValue(self.alloc, base);
                break;
            }
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

    pub fn runStartupCapabilities(self: *TuiApp, dispatcher: inbound.HostDispatcher) void {
        for (self.state.catalog.capabilities) |spec| {
            if (!CatalogState.isAutorunInTui(spec)) continue;
            _ = self.state.selectCapabilityById(spec.id) catch return;
            self.executeActiveCapability(dispatcher) catch |err| {
                self.setStatusFmt("Autorun {s} failed: {s}", .{ spec.id, @errorName(err) });
            };
            return;
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

        try self.dispatchSpec(spec, payload_json, dispatcher);
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
        const hint = "m:Menu  1-9:Focus  z:Zoom  F5:Run  ?:Help  q:Quit ";
        if (w > hint.len + htext.len) {
            screen.drawText(w - @as(u16, @intCast(hint.len)), 0, @intCast(hint.len), hint, header_style);
        }

        // 1b. Capabilities Menubar (row 1)
        self.renderMenubar(screen, 0, 1, w);

        // 2. Footer status bar (row h - 1)
        const footer_style = Style{ .fg = .white, .bg = .bright_black };
        screen.fillRect(0, h - 1, w, 1, ' ', footer_style);
        screen.drawText(1, h - 1, w - 2, self.statusSlice(), footer_style);

        const body_y: u16 = 2;
        const body_h = h - 3;
        const left_count = self.countVisibleInDock(.left);
        const top_count = self.countVisibleInDock(.main_top);
        const bot_count = self.countVisibleInDock(.main_bottom);
        const right_count = self.countVisibleInDock(.right);
        const bottom_count = self.countVisibleInDock(.bottom);

        const has_main = left_count + top_count + bot_count + right_count > 0;
        const bottom_all_collapsed = self.allCollapsedInDock(.bottom);
        const bottom_h: u16 = if (bottom_count == 0)
            0
        else if (!has_main)
            body_h
        else if (bottom_all_collapsed and body_h >= 6)
            3
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
                self.renderDockVertical(screen, .left, 0, body_y, left_w, main_h);
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
                if (top_h > 0) self.renderDockVertical(screen, .main_top, left_w, body_y, center_w, top_h);
                if (bot_h > 0) self.renderDockVertical(screen, .main_bottom, left_w, body_y + top_h, center_w, bot_h);
            }
            if (right_col_w > 0) {
                self.renderDockVertical(screen, .right, left_w + center_w, body_y, right_col_w, main_h);
            }
        }

        // 5. Bottom dock (Telemetry Logs + any custom bottom panels)
        if (bottom_h > 0) {
            self.renderDockHorizontal(screen, .bottom, 0, body_y + main_h, w, bottom_h);
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

    fn allCollapsedInDock(self: *const TuiApp, dock: PanelDock) bool {
        var any = false;
        for (self.panels.items) |p| {
            if (p.visible and p.dock == dock) {
                any = true;
                if (!p.collapsed) return false;
            }
        }
        return any;
    }

    fn renderDockVertical(self: *TuiApp, screen: *Screen, dock: PanelDock, x: u16, y: u16, w: u16, h: u16) void {
        const count = self.countVisibleInDock(dock);
        if (count == 0 or w == 0 or h == 0) return;

        var fixed_total: u16 = 0;
        var flex_count: usize = 0;
        for (self.panels.items) |p| {
            if (!p.visible or p.dock != dock) continue;
            if (p.preferred_height > 0) {
                fixed_total +|= p.preferred_height;
            } else {
                flex_count += 1;
            }
        }

        const min_flex: u16 = @intCast(flex_count * 3);
        const can_use_preferred = (flex_count > 0) and (h >= fixed_total + min_flex);
        const flex_h: u16 = if (flex_count > 0 and can_use_preferred)
            (h - fixed_total) / @as(u16, @intCast(flex_count))
        else
            h / @as(u16, @intCast(count));

        var cur_y = y;
        var seen: usize = 0;
        for (self.panels.items, 0..) |p, idx| {
            if (!p.visible or p.dock != dock) continue;
            seen += 1;
            const ph: u16 = if (seen == count)
                (y + h) - cur_y
            else if (can_use_preferred and p.preferred_height > 0)
                p.preferred_height
            else
                flex_h;
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

    fn renderMenubar(self: *const TuiApp, screen: *Screen, x: u16, y: u16, w: u16) void {
        const bar_bg: term.Color = if (self.menubar_focused) .blue else .bright_black;
        const bar_style = Style{ .fg = .white, .bg = bar_bg };
        screen.fillRect(x, y, w, 1, ' ', bar_style);

        const prefix = if (self.menubar_focused) " [MENU] " else " Menu: ";
        screen.drawText(x, y, w, prefix, .{ .fg = .yellow, .bg = bar_bg, .bold = true });
        var cx: u16 = x + @as(u16, @intCast(@min(w, prefix.len)));

        const items = self.state.sidebar_items.items;
        for (items, 0..) |it, idx| {
            if (cx + 2 >= x + w) break;
            if (it.is_group) {
                if (cx > x + prefix.len) {
                    screen.drawText(cx, y, (x + w) - cx, "│ ", .{ .fg = .white, .bg = bar_bg, .dim = true });
                    cx += 2;
                }
                continue;
            }
            const spec = self.state.catalog.capabilities[it.cap_index];
            const label = spec.title orelse spec.id;
            const selected = idx == self.state.selected_sidebar;
            const active = self.state.active_cap_idx != null and self.state.active_cap_idx.? == it.cap_index;
            const st = Style{
                .fg = if (self.menubar_focused and selected) .black else if (active) .bright_green else .white,
                .bg = if (self.menubar_focused and selected) .cyan else bar_bg,
                .bold = active or (self.menubar_focused and selected),
            };
            var lbuf: [48]u8 = undefined;
            const item_txt = std.fmt.bufPrint(&lbuf, " {s} ", .{label}) catch label;
            const avail = (x + w) - cx;
            const draw_len: u16 = @intCast(@min(avail, item_txt.len));
            screen.drawText(cx, y, draw_len, item_txt[0..draw_len], st);
            cx += draw_len;
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
        const stats = self.ring.stats();
        if (h == 3) {
            var ctitle_buf: [112]u8 = undefined;
            const ctitle = std.fmt.bufPrint(&ctitle_buf, "{s} (minimized)", .{panel_title}) catch panel_title;
            screen.drawBox(x, y, w, h, ctitle, focused, .{});
            var cmsg_buf: [128]u8 = undefined;
            const cmsg = std.fmt.bufPrint(&cmsg_buf, "Press Ctrl+L or panel number to expand | {d} events (dropped: {d})", .{ stats.total, stats.dropped }) catch "Minimized";
            screen.drawText(x + 1, y + 1, w - 2, cmsg, .{ .dim = true });
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
            "m               : Toggle Capabilities Menubar",
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

test "TuiApp runStartupCapabilities executes capability marked with tui.autorun" {
    const alloc = std.testing.allocator;
    const autorun_hints = [_]cap.KeyValue{.{ .key = "tui.autorun", .value = "true" }};
    const catalog = cap.CapabilityCatalog{
        .id = "test_autorun",
        .name = "TestAutorun",
        .version = "1.0.0",
        .capabilities = &.{
            .{
                .id = "other",
                .group = "vfs",
                .title = "Other",
                .output = .{ .kind = .record },
            },
            .{
                .id = "ls",
                .group = "vfs",
                .title = "List Directory",
                .output = .{ .kind = .table },
                .hints = &autorun_hints,
            },
        },
    };

    const MockHost = struct {
        fn dispatch(_: *anyopaque, req: *const abi.InboundRequest_ABI, out_resp: *abi.InboundResponse_ABI) callconv(.c) abi.HostError_ABI {
            if (std.mem.eql(u8, req.command_or_route.toSlice(), "ls")) {
                out_resp.* = .{
                    .status_code = 200,
                    .body = abi.Slice_ABI.from("[{\"name\":\"official\"},{\"name\":\"archives\"}]"),
                };
            } else {
                out_resp.* = .{
                    .status_code = 404,
                    .body = abi.Slice_ABI.from("{}"),
                };
            }
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

    app.runStartupCapabilities(dispatcher);
    try std.testing.expectEqualStrings("ls", app.state.activeCapability().?.id);
    try std.testing.expectEqual(ResultKind.table, app.state.result.kind);
    try std.testing.expectEqual(@as(usize, 2), app.state.result.table_rows.len);
    try std.testing.expectEqual(PanelKind.output, app.focusedPanelKind());
    try std.testing.expectEqualStrings("ls -> HTTP 200", app.statusSlice());
}

test "TuiApp framework Config supports show_sidebar=false, form_on_demand=true, and dispatchCapabilityToOutput" {
    const alloc = std.testing.allocator;
    const catalog = cap.CapabilityCatalog{
        .id = "test_fw",
        .name = "TestFW",
        .version = "1.0.0",
        .capabilities = &.{
            .{
                .id = "preview",
                .group = "view",
                .title = "Preview",
                .output = .{ .kind = .document, .mime_field = "mime_type" },
                .inputs = &.{.{ .name = "id", .required = true }},
            },
        },
    };

    const MockHost = struct {
        fn dispatch(_: *anyopaque, _: *const abi.InboundRequest_ABI, out_resp: *abi.InboundResponse_ABI) callconv(.c) abi.HostError_ABI {
            out_resp.* = .{
                .status_code = 200,
                .body = abi.Slice_ABI.from("{\"mime_type\":\"text/plain\",\"data\":\"hello\"}"),
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
    var app = try TuiApp.init(alloc, catalog, &ring, .{
        .show_sidebar = false,
        .form_on_demand = true,
    });
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 3), app.panels.items.len);
    try std.testing.expect(!app.panels.items[0].visible);
    try std.testing.expectEqual(PanelKind.output, app.focusedPanelKind());

    try app.openCapabilityForm("preview", &.{.{ .name = "id", .value = "f1" }});
    try std.testing.expect(app.panels.items[0].visible);
    try std.testing.expectEqual(PanelKind.form, app.focusedPanelKind());

    try app.dispatchCapabilityToOutput("preview", "{\"id\":\"f1\"}", dispatcher);
    try std.testing.expect(!app.panels.items[0].visible);
    try std.testing.expectEqual(PanelKind.output, app.focusedPanelKind());
    try std.testing.expectEqual(ResultKind.document, app.state.result.kind);
}
