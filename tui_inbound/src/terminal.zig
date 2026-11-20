const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Color = enum(u8) {
    default = 0,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,

    pub fn bgCode(self: Color) u8 {
        return switch (self) {
            .default => 49,
            else => @intFromEnum(self) + 10,
        };
    }

    pub fn fgCode(self: Color) u8 {
        return switch (self) {
            .default => 39,
            else => @intFromEnum(self),
        };
    }
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    reverse: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return a.fg == b.fg and a.bg == b.bg and a.bold == b.bold and a.dim == b.dim and a.reverse == b.reverse;
    }
};

pub const Cell = struct {
    ch: u21 = ' ',
    style: Style = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return a.ch == b.ch and a.style.eql(b.style);
    }
};

pub const Screen = struct {
    alloc: Allocator,
    width: u16 = 0,
    height: u16 = 0,
    cells: []Cell = &.{},
    prev_cells: []Cell = &.{},
    force_full_redraw: bool = true,

    pub fn init(alloc: Allocator) Screen {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Screen) void {
        if (self.cells.len > 0) self.alloc.free(self.cells);
        if (self.prev_cells.len > 0) self.alloc.free(self.prev_cells);
        self.cells = &.{};
        self.prev_cells = &.{};
    }

    pub fn resize(self: *Screen, w: u16, h: u16) !void {
        if (self.width == w and self.height == h and self.cells.len == @as(usize, w) * @as(usize, h)) return;
        const total = @as(usize, w) * @as(usize, h);
        const new_cells = try self.alloc.alloc(Cell, total);
        errdefer self.alloc.free(new_cells);
        const new_prev = try self.alloc.alloc(Cell, total);

        @memset(new_cells, Cell{});
        @memset(new_prev, Cell{ .ch = 0 }); // force initial diff

        if (self.cells.len > 0) self.alloc.free(self.cells);
        if (self.prev_cells.len > 0) self.alloc.free(self.prev_cells);
        self.cells = new_cells;
        self.prev_cells = new_prev;
        self.width = w;
        self.height = h;
        self.force_full_redraw = true;
    }

    pub fn clear(self: *Screen, style: Style) void {
        @memset(self.cells, Cell{ .ch = ' ', .style = style });
    }

    pub fn setCell(self: *Screen, x: u16, y: u16, ch: u21, style: Style) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        self.cells[idx] = .{ .ch = ch, .style = style };
    }

    pub fn fillRect(self: *Screen, x: u16, y: u16, w: u16, h: u16, ch: u21, style: Style) void {
        const x_end = @min(self.width, x +| w);
        const y_end = @min(self.height, y +| h);
        var cy: u16 = y;
        while (cy < y_end) : (cy += 1) {
            var cx: u16 = x;
            while (cx < x_end) : (cx += 1) {
                self.setCell(cx, cy, ch, style);
            }
        }
    }

    pub fn drawText(self: *Screen, x: u16, y: u16, max_w: u16, text: []const u8, style: Style) void {
        if (y >= self.height or x >= self.width or max_w == 0) return;
        const limit = @min(self.width, x +| max_w);
        var cx: u16 = x;
        var i: usize = 0;
        while (i < text.len and cx < limit) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                self.setCell(cx, y, '?', style);
                cx += 1;
                i += 1;
                continue;
            };
            if (i + seq_len > text.len) break;
            const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch '?';
            const display_cp: u21 = if (cp < 0x20 or cp == 0x7f) ' ' else cp;
            self.setCell(cx, y, display_cp, style);
            cx += 1;
            i += seq_len;
        }
    }

    pub fn drawBox(
        self: *Screen,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        title: []const u8,
        focused: bool,
        fill_style: Style,
    ) void {
        if (w < 2 or h < 2) return;
        self.fillRect(x, y, w, h, ' ', fill_style);

        const border_style = Style{
            .fg = if (focused) .bright_cyan else .bright_black,
            .bg = fill_style.bg,
            .bold = focused,
        };
        const title_style = Style{
            .fg = if (focused) .bright_cyan else .white,
            .bg = fill_style.bg,
            .bold = true,
        };

        const x2 = x + w - 1;
        const y2 = y + h - 1;
        self.setCell(x, y, '┌', border_style);
        self.setCell(x2, y, '┐', border_style);
        self.setCell(x, y2, '└', border_style);
        self.setCell(x2, y2, '┘', border_style);

        var cx: u16 = x + 1;
        while (cx < x2) : (cx += 1) {
            self.setCell(cx, y, '─', border_style);
            self.setCell(cx, y2, '─', border_style);
        }
        var cy: u16 = y + 1;
        while (cy < y2) : (cy += 1) {
            self.setCell(x, cy, '│', border_style);
            self.setCell(x2, cy, '│', border_style);
        }

        if (title.len > 0 and w > 4) {
            self.setCell(x + 1, y, ' ', title_style);
            self.drawText(x + 2, y, w - 4, title, title_style);
            const after = @min(x2 - 1, x + 2 + @as(u16, @intCast(@min(title.len, w - 4))));
            self.setCell(after, y, ' ', title_style);
        }
    }

    /// Emits minimal ANSI escape sequences to `writer` for all changed cells.
    pub fn renderDiff(self: *Screen, writer: anytype) !void {
        var last_style: ?Style = null;
        var y: u16 = 0;
        while (y < self.height) : (y += 1) {
            var x: u16 = 0;
            var cursor_valid = false;
            while (x < self.width) : (x += 1) {
                const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
                const cell = self.cells[idx];
                if (!self.force_full_redraw and cell.eql(self.prev_cells[idx])) {
                    cursor_valid = false;
                    continue;
                }
                if (!cursor_valid) {
                    try writer.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                    cursor_valid = true;
                }
                if (last_style == null or !last_style.?.eql(cell.style)) {
                    try writeStyle(writer, cell.style);
                    last_style = cell.style;
                }
                var utf8_buf: [4]u8 = undefined;
                const ulen = std.unicode.utf8Encode(cell.ch, &utf8_buf) catch blk: {
                    utf8_buf[0] = '?';
                    break :blk 1;
                };
                try writer.writeAll(utf8_buf[0..ulen]);
                self.prev_cells[idx] = cell;
            }
        }
        if (last_style != null) {
            try writer.writeAll("\x1b[0m");
        }
        self.force_full_redraw = false;
    }

    fn writeStyle(writer: anytype, s: Style) !void {
        try writer.print("\x1b[0;{d};{d}", .{ s.fg.fgCode(), s.bg.bgCode() });
        if (s.bold) try writer.writeAll(";1");
        if (s.dim) try writer.writeAll(";2");
        if (s.reverse) try writer.writeAll(";7");
        try writer.writeByte('m');
    }
};

/// Clipped drawing surface passed to custom panels so they can render relative to `(0, 0)`
/// without overflowing their allocated panel rectangle.
pub const PanelSurface = struct {
    screen: *Screen,
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn setCell(self: PanelSurface, lx: u16, ly: u16, ch: u21, style: Style) void {
        if (lx >= self.width or ly >= self.height) return;
        self.screen.setCell(self.x + lx, self.y + ly, ch, style);
    }

    pub fn fillRect(self: PanelSurface, lx: u16, ly: u16, w: u16, h: u16, ch: u21, style: Style) void {
        if (lx >= self.width or ly >= self.height) return;
        const cw = @min(w, self.width - lx);
        const ch_h = @min(h, self.height - ly);
        self.screen.fillRect(self.x + lx, self.y + ly, cw, ch_h, ch, style);
    }

    pub fn drawText(self: PanelSurface, lx: u16, ly: u16, max_w: u16, text: []const u8, style: Style) void {
        if (lx >= self.width or ly >= self.height) return;
        const cw = @min(max_w, self.width - lx);
        self.screen.drawText(self.x + lx, self.y + ly, cw, text, style);
    }
};

pub const Key = union(enum) {
    char: u21,
    alt_char: u8,
    enter,
    tab,
    back_tab,
    escape,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    ctrl_c,
    ctrl_q,
    ctrl_r,
    ctrl_k,
    ctrl_l,
    f5,
};

pub const ParsedKey = struct {
    key: Key,
    consumed: usize,
};

/// Decodes a single key event from raw terminal input bytes.
pub fn parseKey(bytes: []const u8) ?ParsedKey {
    if (bytes.len == 0) return null;
    const b0 = bytes[0];

    if (b0 == 0x1b) {
        if (bytes.len == 1) return .{ .key = .escape, .consumed = 1 };
        if (bytes[1] == '[') {
            if (bytes.len >= 3) {
                switch (bytes[2]) {
                    'A' => return .{ .key = .up, .consumed = 3 },
                    'B' => return .{ .key = .down, .consumed = 3 },
                    'C' => return .{ .key = .right, .consumed = 3 },
                    'D' => return .{ .key = .left, .consumed = 3 },
                    'H' => return .{ .key = .home, .consumed = 3 },
                    'F' => return .{ .key = .end, .consumed = 3 },
                    'Z' => return .{ .key = .back_tab, .consumed = 3 },
                    '3' => if (bytes.len >= 4 and bytes[3] == '~') return .{ .key = .delete, .consumed = 4 },
                    '5' => if (bytes.len >= 4 and bytes[3] == '~') return .{ .key = .page_up, .consumed = 4 },
                    '6' => if (bytes.len >= 4 and bytes[3] == '~') return .{ .key = .page_down, .consumed = 4 },
                    '1' => if (bytes.len >= 5 and bytes[3] == '5' and bytes[4] == '~') return .{ .key = .f5, .consumed = 5 },
                    else => {},
                }
            }
            return .{ .key = .escape, .consumed = 1 };
        }
        if (bytes[1] >= '1' and bytes[1] <= '9') {
            return .{ .key = .{ .alt_char = bytes[1] }, .consumed = 2 };
        }
        return .{ .key = .escape, .consumed = 1 };
    }

    switch (b0) {
        '\r', '\n' => return .{ .key = .enter, .consumed = 1 },
        '\t' => return .{ .key = .tab, .consumed = 1 },
        127, 8 => return .{ .key = .backspace, .consumed = 1 },
        3 => return .{ .key = .ctrl_c, .consumed = 1 },
        17 => return .{ .key = .ctrl_q, .consumed = 1 },
        18 => return .{ .key = .ctrl_r, .consumed = 1 },
        11 => return .{ .key = .ctrl_k, .consumed = 1 },
        12 => return .{ .key = .ctrl_l, .consumed = 1 },
        else => {},
    }

    if (b0 < 0x20) return .{ .key = .{ .char = ' ' }, .consumed = 1 };

    const seq_len = std.unicode.utf8ByteSequenceLength(b0) catch return .{ .key = .{ .char = '?' }, .consumed = 1 };
    if (seq_len > bytes.len) return null;
    const cp = std.unicode.utf8Decode(bytes[0..seq_len]) catch '?';
    return .{ .key = .{ .char = cp }, .consumed = seq_len };
}

pub const RawTerminal = struct {
    orig_termios: std.c.termios = undefined,
    active: bool = false,
    stdin_fd: std.c.fd_t = std.c.STDIN_FILENO,
    stdout_fd: std.c.fd_t = std.c.STDOUT_FILENO,
    saved_stderr_fd: ?std.c.fd_t = null,
    stderr_pipe: [2]std.c.fd_t = .{ -1, -1 },

    pub fn enter(self: *RawTerminal) !void {
        if (std.c.tcgetattr(self.stdin_fd, &self.orig_termios) != 0) {
            return error.NotATerminal;
        }
        var raw = self.orig_termios;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;

        if (std.c.tcsetattr(self.stdin_fd, .FLUSH, &raw) != 0) {
            return error.TermiosFailed;
        }
        self.active = true;

        // Isolate stderr so engine/driver logs never corrupt raw-mode TUI rendering
        const saved = std.c.dup(std.c.STDERR_FILENO);
        if (saved >= 0) {
            if (std.c.pipe(&self.stderr_pipe) == 0) {
                _ = std.c.dup2(self.stderr_pipe[1], std.c.STDERR_FILENO);
                self.saved_stderr_fd = saved;
            } else {
                _ = std.c.close(saved);
            }
        }

        self.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J");
    }

    pub fn leave(self: *RawTerminal) void {
        if (!self.active) return;
        self.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l");
        if (self.saved_stderr_fd) |saved| {
            _ = std.c.dup2(saved, std.c.STDERR_FILENO);
            _ = std.c.close(saved);
            self.saved_stderr_fd = null;
        }
        if (self.stderr_pipe[0] >= 0) {
            _ = std.c.close(self.stderr_pipe[0]);
            self.stderr_pipe[0] = -1;
        }
        if (self.stderr_pipe[1] >= 0) {
            _ = std.c.close(self.stderr_pipe[1]);
            self.stderr_pipe[1] = -1;
        }
        _ = std.c.tcsetattr(self.stdin_fd, .FLUSH, &self.orig_termios);
        self.active = false;
    }

    pub fn getSize(self: *const RawTerminal) struct { w: u16, h: u16 } {
        var ws: std.c.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        if (std.c.ioctl(self.stdout_fd, std.c.T.IOCGWINSZ, @intFromPtr(&ws)) == 0) {
            return .{
                .w = if (ws.col > 0) ws.col else 80,
                .h = if (ws.row > 0) ws.row else 24,
            };
        }
        return .{ .w = 80, .h = 24 };
    }

    pub fn writeAll(self: *const RawTerminal, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.c.write(self.stdout_fd, bytes[off..].ptr, bytes.len - off);
            if (rc <= 0) break;
            off += @intCast(rc);
        }
    }

    pub const PollResult = struct {
        stdin_len: usize = 0,
        stderr_len: usize = 0,
    };

    /// Waits for stdin, stderr pipe, or optional wakeup pipe.
    pub fn pollRead(
        self: *const RawTerminal,
        wakeup_read_fd: ?std.c.fd_t,
        timeout_ms: i32,
        stdin_buf: []u8,
        stderr_buf: []u8,
    ) PollResult {
        var fds: [3]std.c.pollfd = undefined;
        fds[0] = .{ .fd = self.stdin_fd, .events = std.c.POLL.IN, .revents = 0 };
        var nfds: usize = 1;
        var wake_idx: ?usize = null;
        var err_idx: ?usize = null;

        if (wakeup_read_fd) |wfd| {
            wake_idx = nfds;
            fds[nfds] = .{ .fd = wfd, .events = std.c.POLL.IN, .revents = 0 };
            nfds += 1;
        }
        if (self.stderr_pipe[0] >= 0) {
            err_idx = nfds;
            fds[nfds] = .{ .fd = self.stderr_pipe[0], .events = std.c.POLL.IN, .revents = 0 };
            nfds += 1;
        }

        const prc = std.c.poll(&fds, @intCast(nfds), timeout_ms);
        if (prc <= 0) return .{};

        var res = PollResult{};
        if (wake_idx) |wi| {
            if ((fds[wi].revents & std.c.POLL.IN) != 0) {
                var drain: [64]u8 = undefined;
                _ = std.c.read(fds[wi].fd, &drain, drain.len);
            }
        }
        if (err_idx) |ei| {
            if ((fds[ei].revents & std.c.POLL.IN) != 0) {
                const n = std.c.read(fds[ei].fd, stderr_buf.ptr, stderr_buf.len);
                if (n > 0) res.stderr_len = @intCast(n);
            }
        }
        if ((fds[0].revents & std.c.POLL.IN) != 0) {
            const n = std.c.read(self.stdin_fd, stdin_buf.ptr, stdin_buf.len);
            if (n > 0) res.stdin_len = @intCast(n);
        }
        return res;
    }
};

test "Screen renderDiff emits only changed cells and parses keys" {
    const alloc = std.testing.allocator;
    var scr = Screen.init(alloc);
    defer scr.deinit();

    try scr.resize(10, 4);
    scr.drawBox(0, 0, 10, 4, "Hi", true, .{});
    scr.drawText(2, 1, 6, "Hello", .{ .fg = .green });

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try scr.renderDiff(&aw.writer);
    try std.testing.expect(aw.written().len > 0);

    // Second render without changes emits nothing
    var aw2: std.Io.Writer.Allocating = .init(alloc);
    defer aw2.deinit();
    try scr.renderDiff(&aw2.writer);
    try std.testing.expectEqual(@as(usize, 0), aw2.written().len);

    // Key parsing checks
    try std.testing.expectEqual(Key.up, parseKey("\x1b[A").?.key);
    try std.testing.expectEqual(Key.back_tab, parseKey("\x1b[Z").?.key);
    try std.testing.expectEqual(Key.f5, parseKey("\x1b[15~").?.key);
    try std.testing.expectEqual(@as(u21, 'a'), parseKey("a").?.key.char);
}
