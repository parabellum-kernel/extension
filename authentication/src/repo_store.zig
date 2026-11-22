const std = @import("std");
const sdk = @import("parabellum_sdk");
const mfa = @import("parabellum_mfa");
const constants = @import("constants.zig");
const abi = sdk.abi;
const Table = constants.Table;
const Column = constants.Column;

/// Adapts a C-ABI `(RepoHandle_ABI, *const StorageRepositoryVTable_ABI)` datasource
/// into `mfa.AttemptTracker`, `mfa.FactorStateStore` (CAS via `expected_version`),
/// `mfa.ReplayGuard`, and `mfa.AuditSink`.
pub const RepoMfaStoreAdapter = struct {
    allocator: std.mem.Allocator,
    repo: *abi.driver.RepoHandle_ABI,
    vtable: *const abi.driver.StorageRepositoryVTable_ABI,
    max_failures: u32 = constants.Defaults.max_failures,
    lockout_s: u64 = constants.Defaults.lockout_s,
    audit_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    next_res_token: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    reservations: std.AutoHashMapUnmanaged(u64, PendingReservation) = .empty,
    kernel_handle: ?*abi.extension.KernelHandle_ABI = null,
    emit_log_fn: ?*const fn (kernel: *abi.extension.KernelHandle_ABI, level: u32, msg: abi.Slice_ABI) callconv(.c) abi.HostError_ABI = null,

    const PendingReservation = struct {
        attempt_key: []u8,
        subject_id: []u8,
        factor_id: ?[]u8,
        session_id: ?[]u8,
        source_key: ?[]u8,
        op: mfa.AttemptTracker.AttemptOp,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        repo: *abi.driver.RepoHandle_ABI,
        vtable: *const abi.driver.StorageRepositoryVTable_ABI,
    ) RepoMfaStoreAdapter {
        return .{
            .allocator = allocator,
            .repo = repo,
            .vtable = vtable,
        };
    }

    pub fn deinit(self: *RepoMfaStoreAdapter) void {
        var it = self.reservations.valueIterator();
        while (it.next()) |r| {
            self.allocator.free(r.attempt_key);
            self.allocator.free(r.subject_id);
            if (r.factor_id) |f| self.allocator.free(f);
            if (r.session_id) |sid| self.allocator.free(sid);
            if (r.source_key) |s| self.allocator.free(s);
        }
        self.reservations.deinit(self.allocator);
    }

    pub fn attemptTracker(self: *RepoMfaStoreAdapter) mfa.AttemptTracker {
        return .{ .ptr = self, .vtable = &attempt_vtable };
    }

    pub fn factorStateStore(self: *RepoMfaStoreAdapter) mfa.FactorStateStore {
        return .{ .ptr = self, .vtable = &state_vtable };
    }

    pub fn replayGuard(self: *RepoMfaStoreAdapter) mfa.ReplayGuard {
        return .{ .ptr = self, .vtable = &replay_vtable };
    }

    pub fn auditSink(self: *RepoMfaStoreAdapter) mfa.AuditSink {
        return .{ .ptr = self, .vtable = &audit_vtable };
    }

    fn beginTx(self: *RepoMfaStoreAdapter) bool {
        if (self.vtable.begin_tx) |f| {
            return f(self.repo) == .ok;
        }
        return true;
    }

    fn commitTx(self: *RepoMfaStoreAdapter) bool {
        if (self.vtable.commit) |f| {
            return f(self.repo) == .ok;
        }
        return true;
    }

    fn rollbackTx(self: *RepoMfaStoreAdapter) void {
        if (self.vtable.rollback) |f| {
            _ = f(self.repo);
        }
    }

    fn findField(row: abi.RowView_ABI, name: []const u8) ?abi.common.Value_ABI {
        for (row.fieldsSlice()) |f| {
            if (std.mem.eql(u8, std.mem.span(f.name), name)) return f.value;
        }
        return null;
    }

    fn fieldAsInt(row: abi.RowView_ABI, name: []const u8) ?i64 {
        const v = findField(row, name) orelse return null;
        return switch (v.tag) {
            .int_val => v.payload.i,
            .uint_val => @intCast(v.payload.u),
            else => null,
        };
    }

    fn fieldAsBytes(row: abi.RowView_ABI, name: []const u8) ?[]const u8 {
        const v = findField(row, name) orelse return null;
        return switch (v.tag) {
            .bytes_val => v.payload.bytes.toSlice(),
            else => null,
        };
    }

    fn upsertRow(self: *RepoMfaStoreAdapter, table: []const u8, fields: []const abi.NamedField_ABI) bool {
        const write_row = self.vtable.write_row orelse return false;
        const spec = abi.driver.WriteSpec_ABI{
            .table = abi.Slice_ABI.from(table),
            .mode = .upsert,
            .fields_ptr = fields.ptr,
            .fields_len = fields.len,
        };
        return write_row(self.repo, &spec) == .ok;
    }

    fn openIter(self: *RepoMfaStoreAdapter, table: []const u8, filter: []const u8) ?abi.driver.RowIterator_ABI {
        const read_stream = self.vtable.read_stream orelse return null;
        const spec = abi.driver.ReadSpec_ABI{
            .table = abi.Slice_ABI.from(table),
            .limit = 1,
            .offset = 0,
            .filter_sql_or_expr = abi.Slice_ABI.from(filter),
        };
        var iter: abi.driver.RowIterator_ABI = undefined;
        if (read_stream(self.repo, &spec, &iter) != .ok) return null;
        return iter;
    }

    fn makeAttemptKey(self: *RepoMfaStoreAdapter, scope: mfa.AttemptTracker.AttemptScope) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}:{s}:{s}",
            .{ scope.subject_id, scope.factor_id orelse "*", scope.source_key orelse "*" },
        );
    }

    fn reserve(
        ctx: *anyopaque,
        op: mfa.AttemptTracker.AttemptOp,
        scope: mfa.AttemptTracker.AttemptScope,
        now_unix_s: i64,
    ) mfa.AttemptTracker.TrackerError!mfa.AttemptTracker.ReserveDecision {
        const self: *RepoMfaStoreAdapter = @ptrCast(@alignCast(ctx));
        const key = self.makeAttemptKey(scope) catch return error.OutOfMemory;
        errdefer self.allocator.free(key);

        const filter = std.fmt.allocPrint(self.allocator, "attempt_key = '{s}'", .{key}) catch return error.OutOfMemory;
        defer self.allocator.free(filter);

        if (self.openIter(Table.mfa_attempts.name(), filter)) |iter_val| {
            var iter = iter_val;
            defer iter.vtable.deinit(iter.handle);
            var row: abi.RowView_ABI = undefined;
            if (iter.vtable.next(iter.handle, &row) == .ok) {
                const locked_until = fieldAsInt(row, Column.locked_until.name()) orelse 0;
                if (locked_until > now_unix_s) {
                    self.allocator.free(key);
                    return .{ .locked_out = .{ .retry_after_s = @intCast(locked_until - now_unix_s) } };
                }
            }
        }

        const tok = self.next_res_token.fetchAdd(1, .monotonic);
        const subj_dup = self.allocator.dupe(u8, scope.subject_id) catch return error.OutOfMemory;
        errdefer self.allocator.free(subj_dup);
        const fid_dup: ?[]u8 = if (scope.factor_id) |f| (self.allocator.dupe(u8, f) catch return error.OutOfMemory) else null;
        errdefer if (fid_dup) |f| self.allocator.free(f);
        const sid_dup: ?[]u8 = if (scope.session_id) |sid| (self.allocator.dupe(u8, sid) catch return error.OutOfMemory) else null;
        errdefer if (sid_dup) |sid| self.allocator.free(sid);
        const src_dup: ?[]u8 = if (scope.source_key) |s| (self.allocator.dupe(u8, s) catch return error.OutOfMemory) else null;
        errdefer if (src_dup) |s| self.allocator.free(s);

        self.reservations.put(self.allocator, tok, .{
            .attempt_key = key,
            .subject_id = subj_dup,
            .factor_id = fid_dup,
            .session_id = sid_dup,
            .source_key = src_dup,
            .op = op,
        }) catch return error.OutOfMemory;
        return .{ .granted = .{ .token = tok } };
    }

    fn hasEnrollmentRow(self: *RepoMfaStoreAdapter, enrollment_id: []const u8) bool {
        const filter = std.fmt.allocPrint(self.allocator, "enrollment_id = '{s}'", .{enrollment_id}) catch return false;
        defer self.allocator.free(filter);
        const iter_val = self.openIter(Table.mfa_factor_enrollments.name(), filter) orelse return false;
        var iter = iter_val;
        defer iter.vtable.deinit(iter.handle);
        var row: abi.RowView_ABI = undefined;
        return iter.vtable.next(iter.handle, &row) == .ok;
    }

    fn settle(
        ctx: *anyopaque,
        reservation: mfa.AttemptTracker.Reservation,
        outcome: mfa.AttemptTracker.AttemptOutcome,
        now_unix_s: i64,
    ) mfa.AttemptTracker.TrackerError!void {
        const self: *RepoMfaStoreAdapter = @ptrCast(@alignCast(ctx));
        const kv = self.reservations.fetchRemove(reservation.token) orelse return;
        defer {
            self.allocator.free(kv.value.attempt_key);
            self.allocator.free(kv.value.subject_id);
            if (kv.value.factor_id) |f| self.allocator.free(f);
            if (kv.value.session_id) |sid| self.allocator.free(sid);
            if (kv.value.source_key) |s| self.allocator.free(s);
        }

        if (outcome != .rejected and outcome != .verified) return;
        if (!self.beginTx()) return error.TrackerUnavailable;
        errdefer self.rollbackTx();

        var fail_count: i64 = 0;
        const filter = std.fmt.allocPrint(self.allocator, "attempt_key = '{s}'", .{kv.value.attempt_key}) catch return error.OutOfMemory;
        defer self.allocator.free(filter);

        if (self.openIter(Table.mfa_attempts.name(), filter)) |iter_val| {
            var iter = iter_val;
            defer iter.vtable.deinit(iter.handle);
            var row: abi.RowView_ABI = undefined;
            if (iter.vtable.next(iter.handle, &row) == .ok) {
                fail_count = fieldAsInt(row, Column.fail_count.name()) orelse 0;
            }
        }

        var locked_until: i64 = 0;
        if (outcome == .verified) {
            fail_count = 0;
        } else if (outcome == .rejected) {
            fail_count += 1;
            if (fail_count >= @as(i64, self.max_failures)) {
                locked_until = now_unix_s + @as(i64, @intCast(self.lockout_s));
            }
        }

        var enrollment_id_buf: ?[]u8 = null;
        defer if (enrollment_id_buf) |eid| self.allocator.free(eid);
        if (kv.value.factor_id) |fid| {
            const candidate = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ kv.value.subject_id, fid }) catch return error.OutOfMemory;
            if (self.hasEnrollmentRow(candidate)) {
                enrollment_id_buf = candidate;
            } else {
                self.allocator.free(candidate);
            }
        }

        const fields = [_]abi.NamedField_ABI{
            .{ .name = Column.attempt_key.nameZ(), .value = abi.common.Value_ABI.fromBytes(kv.value.attempt_key) },
            .{ .name = Column.subject_id.nameZ(), .value = abi.common.Value_ABI.fromBytes(kv.value.subject_id) },
            .{ .name = Column.factor_id.nameZ(), .value = if (kv.value.factor_id) |f| abi.common.Value_ABI.fromBytes(f) else .{ .tag = .null_val, .payload = .{ .i = 0 } } },
            .{ .name = Column.enrollment_id.nameZ(), .value = if (enrollment_id_buf) |eid| abi.common.Value_ABI.fromBytes(eid) else .{ .tag = .null_val, .payload = .{ .i = 0 } } },
            .{ .name = Column.session_id.nameZ(), .value = if (kv.value.session_id) |sid| abi.common.Value_ABI.fromBytes(sid) else .{ .tag = .null_val, .payload = .{ .i = 0 } } },
            .{ .name = Column.source_key.nameZ(), .value = if (kv.value.source_key) |s| abi.common.Value_ABI.fromBytes(s) else .{ .tag = .null_val, .payload = .{ .i = 0 } } },
            .{ .name = Column.fail_count.nameZ(), .value = abi.common.Value_ABI.fromInt(fail_count) },
            .{ .name = Column.locked_until.nameZ(), .value = abi.common.Value_ABI.fromInt(locked_until) },
            .{ .name = Column.updated_at.nameZ(), .value = abi.common.Value_ABI.fromInt(now_unix_s) },
        };
        if (!self.upsertRow(Table.mfa_attempts.name(), &fields)) return error.TrackerUnavailable;
        if (!self.commitTx()) return error.TrackerUnavailable;
    }

    const attempt_vtable = mfa.AttemptTracker.VTable{
        .reserve = reserve,
        .settle = settle,
    };

    fn loadState(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        subject_id: []const u8,
        factor_id: []const u8,
    ) mfa.FactorStateStore.StoreError!mfa.FactorStateStore.FactorStateSnapshot {
        const self: *RepoMfaStoreAdapter = @ptrCast(@alignCast(ctx));
        const filter = std.fmt.allocPrint(self.allocator, "enrollment_id = '{s}:{s}'", .{ subject_id, factor_id }) catch return error.OutOfMemory;
        defer self.allocator.free(filter);

        const iter_val = self.openIter(Table.mfa_factor_enrollments.name(), filter) orelse {
            return .{ .bytes = null, .version = 0 };
        };
        var iter = iter_val;
        defer iter.vtable.deinit(iter.handle);

        var row: abi.RowView_ABI = undefined;
        if (iter.vtable.next(iter.handle, &row) != .ok) {
            return .{ .bytes = null, .version = 0 };
        }
        const ver_i = fieldAsInt(row, Column.version.name()) orelse 0;
        const raw = fieldAsBytes(row, Column.sealed_state.name());
        const duped: ?[]u8 = if (raw) |b| (allocator.dupe(u8, b) catch return error.OutOfMemory) else null;
        return .{
            .bytes = duped,
            .version = if (ver_i < 0) 0 else @intCast(ver_i),
        };
    }

    fn commitState(
        ctx: *anyopaque,
        subject_id: []const u8,
        factor_id: []const u8,
        expected_version: u64,
        state_update: []const u8,
    ) mfa.FactorStateStore.StoreError!mfa.FactorStateStore.CommitResult {
        const self: *RepoMfaStoreAdapter = @ptrCast(@alignCast(ctx));
        if (!self.beginTx()) return error.StoreUnavailable;
        errdefer self.rollbackTx();

        const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ subject_id, factor_id }) catch return error.OutOfMemory;
        defer self.allocator.free(key);
        const filter = std.fmt.allocPrint(self.allocator, "enrollment_id = '{s}'", .{key}) catch return error.OutOfMemory;
        defer self.allocator.free(filter);

        var current_version: u64 = 0;
        if (self.openIter(Table.mfa_factor_enrollments.name(), filter)) |iter_val| {
            var iter = iter_val;
            defer iter.vtable.deinit(iter.handle);
            var row: abi.RowView_ABI = undefined;
            if (iter.vtable.next(iter.handle, &row) == .ok) {
                const v = fieldAsInt(row, Column.version.name()) orelse 0;
                current_version = if (v < 0) 0 else @intCast(v);
            }
        }

        if (current_version != expected_version) {
            self.rollbackTx();
            return .conflict;
        }

        const next_version: i64 = @intCast(expected_version + 1);
        const fields = [_]abi.NamedField_ABI{
            .{ .name = Column.enrollment_id.nameZ(), .value = abi.common.Value_ABI.fromBytes(key) },
            .{ .name = Column.subject_id.nameZ(), .value = abi.common.Value_ABI.fromBytes(subject_id) },
            .{ .name = Column.factor_id.nameZ(), .value = abi.common.Value_ABI.fromBytes(factor_id) },
            .{ .name = Column.status.nameZ(), .value = abi.common.Value_ABI.fromBytes("enrolled") },
            .{ .name = Column.version.nameZ(), .value = abi.common.Value_ABI.fromInt(next_version) },
            .{ .name = Column.sealed_state.nameZ(), .value = abi.common.Value_ABI.fromBytes(state_update) },
            .{ .name = Column.enrolled_at.nameZ(), .value = abi.common.Value_ABI.fromInt(0) },
            .{ .name = Column.updated_at.nameZ(), .value = abi.common.Value_ABI.fromInt(0) },
        };
        if (!self.upsertRow(Table.mfa_factor_enrollments.name(), &fields)) return error.StoreUnavailable;
        if (!self.commitTx()) return error.StoreUnavailable;
        return .committed;
    }

    fn isPersistent(_: *anyopaque) bool {
        return true;
    }

    const state_vtable = mfa.FactorStateStore.VTable{
        .load = loadState,
        .commit = commitState,
        .isPersistent = isPersistent,
    };

    fn markUsed(ctx: *anyopaque, jti: []const u8, exp: i64) mfa.ReplayGuard.GuardError!mfa.ReplayGuard.Status {
        const self: *RepoMfaStoreAdapter = @ptrCast(@alignCast(ctx));
        if (!self.beginTx()) return error.GuardUnavailable;
        errdefer self.rollbackTx();

        const filter = std.fmt.allocPrint(self.allocator, "jti = '{s}'", .{jti}) catch return error.OutOfMemory;
        defer self.allocator.free(filter);

        if (self.openIter(Table.mfa_replay_jti.name(), filter)) |iter_val| {
            var iter = iter_val;
            defer iter.vtable.deinit(iter.handle);
            var row: abi.RowView_ABI = undefined;
            if (iter.vtable.next(iter.handle, &row) == .ok) {
                self.rollbackTx();
                return .replayed;
            }
        }

        const fields = [_]abi.NamedField_ABI{
            .{ .name = Column.jti.nameZ(), .value = abi.common.Value_ABI.fromBytes(jti) },
            .{ .name = Column.exp.nameZ(), .value = abi.common.Value_ABI.fromInt(exp) },
        };
        if (!self.upsertRow(Table.mfa_replay_jti.name(), &fields)) return error.GuardUnavailable;
        if (!self.commitTx()) return error.GuardUnavailable;
        return .fresh;
    }

    const replay_vtable = mfa.ReplayGuard.VTable{ .markUsed = markUsed };

    fn emitAudit(ctx: *anyopaque, event: mfa.AuditSink.AuditEvent) void {
        const self: *RepoMfaStoreAdapter = @ptrCast(@alignCast(ctx));
        const seq = self.audit_seq.fetchAdd(1, .monotonic);
        var id_buf: [32]u8 = undefined;
        const event_id = std.fmt.bufPrint(&id_buf, "mfa-{d}-{d}", .{ event.now_unix_s, seq }) catch "mfa-evt";
        const kind_str = @tagName(event.kind);

        const fields = [_]abi.NamedField_ABI{
            .{ .name = Column.event_id.nameZ(), .value = abi.common.Value_ABI.fromBytes(event_id) },
            .{ .name = Column.kind.nameZ(), .value = abi.common.Value_ABI.fromBytes(kind_str) },
            .{ .name = Column.occurred_at.nameZ(), .value = abi.common.Value_ABI.fromInt(event.now_unix_s) },
            .{ .name = Column.subject_id.nameZ(), .value = abi.common.Value_ABI.fromBytes(event.subject_id orelse "") },
            .{ .name = Column.session_id.nameZ(), .value = abi.common.Value_ABI.fromBytes(event.session_id orelse "") },
            .{ .name = Column.factor_id.nameZ(), .value = abi.common.Value_ABI.fromBytes(event.factor_id orelse "") },
            .{ .name = Column.source_key.nameZ(), .value = abi.common.Value_ABI.fromBytes(event.source_key orelse "") },
            .{ .name = Column.detail.nameZ(), .value = abi.common.Value_ABI.fromInt(@intCast(event.detail)) },
        };
        _ = self.upsertRow(Table.mfa_audit_log.name(), &fields);

        if (self.emit_log_fn) |log_fn| {
            if (self.kernel_handle) |kh| {
                var msg_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &msg_buf,
                    "[AUTH] kind={s} subject={s} factor={s} detail={d}",
                    .{ kind_str, event.subject_id orelse "-", event.factor_id orelse "-", event.detail },
                ) catch return;
                _ = log_fn(kh, 1, abi.Slice_ABI.from(msg));
            }
        }
    }

    const audit_vtable = mfa.AuditSink.VTable{ .emit = emitAudit };
};

test "RepoMfaStoreAdapter CAS, AttemptTracker lockout, and ReplayGuard over StorageRepositoryVTable_ABI" {
    const MockRepo = struct {
        const Entry = struct {
            key: []u8,
            int_val: i64 = 0,
            int_val2: i64 = 0,
            bytes_val: []u8,
        };

        alloc: std.mem.Allocator,
        rows: std.StringHashMapUnmanaged(Entry) = .empty,

        fn deinit(self: *@This()) void {
            var it = self.rows.iterator();
            while (it.next()) |e| {
                self.alloc.free(e.key_ptr.*);
                self.alloc.free(e.value_ptr.key);
                self.alloc.free(e.value_ptr.bytes_val);
            }
            self.rows.deinit(self.alloc);
        }

        const Iter = struct {
            done: bool = false,
            found: ?Entry = null,
            fields: [4]abi.NamedField_ABI = undefined,
            fn next(h: *abi.driver.RowIteratorHandle_ABI, out: *abi.RowView_ABI) callconv(.c) abi.HostError_ABI {
                const self: *Iter = @ptrCast(@alignCast(h));
                if (self.done) return .end_of_stream;
                const e = self.found orelse return .end_of_stream;
                self.done = true;
                self.fields = .{
                    .{ .name = "attempt_key", .value = abi.common.Value_ABI.fromBytes(e.key) },
                    .{ .name = "fail_count", .value = abi.common.Value_ABI.fromInt(e.int_val) },
                    .{ .name = "locked_until", .value = abi.common.Value_ABI.fromInt(e.int_val2) },
                    .{ .name = "version", .value = abi.common.Value_ABI.fromInt(e.int_val) },
                };
                out.* = .{ .fields_ptr = &self.fields, .fields_len = self.fields.len };
                return .ok;
            }
            fn deinitIter(h: *abi.driver.RowIteratorHandle_ABI) callconv(.c) void {
                const self: *Iter = @ptrCast(@alignCast(h));
                std.testing.allocator.destroy(self);
            }
            const vt = abi.driver.RowIteratorVTable_ABI{ .next = next, .deinit = deinitIter };
        };

        fn getCaps(_: *const abi.driver.RepoHandle_ABI) callconv(.c) abi.driver.DriverCapabilities_ABI {
            return .{ .read = true, .write = true, .transactions = true };
        }
        fn recCount(_: *const abi.driver.RepoHandle_ABI, _: abi.Slice_ABI) callconv(.c) usize {
            return 0;
        }
        fn deinitRepo(_: *abi.driver.RepoHandle_ABI) callconv(.c) void {}
        fn okTx(_: *abi.driver.RepoHandle_ABI) callconv(.c) abi.HostError_ABI {
            return .ok;
        }
        fn writeRow(h: *abi.driver.RepoHandle_ABI, spec: *const abi.driver.WriteSpec_ABI) callconv(.c) abi.HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(h));
            const table = spec.table.toSlice();
            const fs = spec.fieldsSlice();
            const pk = fs[0].value.payload.bytes.toSlice();
            const full_key = std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ table, pk }) catch return .out_of_memory;
            if (self.rows.fetchRemove(full_key)) |old| {
                self.alloc.free(old.key);
                self.alloc.free(old.value.key);
                self.alloc.free(old.value.bytes_val);
            }
            var val_i1: i64 = 0;
            var val_i2: i64 = 0;
            var bv: []const u8 = "";
            for (fs) |f| {
                const n = std.mem.span(f.name);
                if (std.mem.eql(u8, n, "fail_count") or std.mem.eql(u8, n, "version")) val_i1 = f.value.payload.i;
                if (std.mem.eql(u8, n, "locked_until")) val_i2 = f.value.payload.i;
                if (std.mem.eql(u8, n, "sealed_state")) bv = f.value.payload.bytes.toSlice();
            }
            self.rows.put(self.alloc, full_key, .{
                .key = self.alloc.dupe(u8, pk) catch return .out_of_memory,
                .int_val = val_i1,
                .int_val2 = val_i2,
                .bytes_val = self.alloc.dupe(u8, bv) catch return .out_of_memory,
            }) catch return .out_of_memory;
            return .ok;
        }
        fn readStream(h: *abi.driver.RepoHandle_ABI, spec: *const abi.driver.ReadSpec_ABI, out_iter: *abi.driver.RowIterator_ABI) callconv(.c) abi.HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(h));
            const f = spec.filter_sql_or_expr.toSlice();
            const q1 = std.mem.indexOfScalar(u8, f, '\'') orelse return .invalid_argument;
            const q2 = std.mem.lastIndexOfScalar(u8, f, '\'') orelse return .invalid_argument;
            const pk = f[q1 + 1 .. q2];
            const full_key = std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ spec.table.toSlice(), pk }) catch return .out_of_memory;
            defer self.alloc.free(full_key);

            const it = self.alloc.create(Iter) catch return .out_of_memory;
            it.* = .{ .found = self.rows.get(full_key) };
            out_iter.* = .{ .handle = @ptrCast(it), .vtable = &Iter.vt };
            return .ok;
        }

        const vtable = abi.driver.StorageRepositoryVTable_ABI{
            .get_capabilities = getCaps,
            .record_count = recCount,
            .deinit = deinitRepo,
            .write_row = writeRow,
            .read_stream = readStream,
            .begin_tx = okTx,
            .commit = okTx,
            .rollback = okTx,
        };
    };

    var mock = MockRepo{ .alloc = std.testing.allocator };
    defer mock.deinit();

    var adapter = RepoMfaStoreAdapter.init(std.testing.allocator, @ptrCast(&mock), &MockRepo.vtable);
    adapter.max_failures = 2;
    adapter.lockout_s = 60;
    defer adapter.deinit();

    // 1. FactorStateStore CAS
    const store = adapter.factorStateStore();
    try std.testing.expectEqual(mfa.FactorStateStore.CommitResult.committed, try store.commit("u1", "totp", 0, "s1"));
    try std.testing.expectEqual(mfa.FactorStateStore.CommitResult.conflict, try store.commit("u1", "totp", 0, "s2"));
    try std.testing.expectEqual(mfa.FactorStateStore.CommitResult.committed, try store.commit("u1", "totp", 1, "s2"));

    // 2. AttemptTracker lockout
    const tracker = adapter.attemptTracker();
    const r1 = try tracker.reserve(.verify, .{ .subject_id = "u1", .factor_id = "password" }, 100);
    try tracker.settle(r1.granted, .rejected, 100);
    const r2 = try tracker.reserve(.verify, .{ .subject_id = "u1", .factor_id = "password" }, 101);
    try tracker.settle(r2.granted, .rejected, 101);
    const r3 = try tracker.reserve(.verify, .{ .subject_id = "u1", .factor_id = "password" }, 102);
    try std.testing.expect(r3 == .locked_out);

    // 3. ReplayGuard
    const rg = adapter.replayGuard();
    try std.testing.expectEqual(mfa.ReplayGuard.Status.fresh, try rg.markUsed("jti-1", 200));
    try std.testing.expectEqual(mfa.ReplayGuard.Status.replayed, try rg.markUsed("jti-1", 200));
}
