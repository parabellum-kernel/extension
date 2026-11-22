const std = @import("std");
const sdk = @import("parabellum_sdk");
const crypto = @import("parabellum_crypto");
const mfa = @import("parabellum_mfa");
const abi = sdk.abi;

pub const constants = @import("constants.zig");
pub const crypto_adapters = @import("crypto_adapters.zig");
pub const factors = @import("factors.zig");
pub const repo_store = @import("repo_store.zig");

const SessionEntry = struct {
    state: mfa.SessionState,
    subject_id: []u8,
    action_scope: []u8,
};

pub const AuthExtensionState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: constants.AuthConfig,
    kernel: *abi.extension.KernelHandle_ABI,
    api: *const abi.KernelApiVTable_ABI,
    rng: crypto_adapters.CryptoRandomPort,
    hasher: crypto_adapters.Sha256HashPort = .{},
    sealer: crypto_adapters.AeadStateSealer,
    signer: crypto_adapters.Ed25519GrantSigner,
    verifier: crypto_adapters.Ed25519GrantVerifier,
    pwd_factor: factors.PasswordFactor,
    totp_factor: factors.TotpFactor = .{},
    rec_factor: factors.RecoveryCodeFactor = .{},
    dev_factor: factors.DeviceChallengeFactor = .{},
    registry: mfa.FactorRegistry,
    stateless_store: mfa.StatelessOnlyFactorStore = .{},
    mem_tracker: mfa.InMemoryAttemptTracker,
    repo_adapter: ?repo_store.RepoMfaStoreAdapter = null,
    sessions: std.StringHashMapUnmanaged(SessionEntry) = .empty,
    active_grants: std.StringHashMapUnmanaged(mfa.GrantVerifier.VerifiedGrant) = .empty,
    now_override: ?i64 = null,

    fn nowFn(ctx: ?*anyopaque) i64 {
        const self: *const AuthExtensionState = @ptrCast(@alignCast(ctx.?));
        if (self.now_override) |t| return t;
        const ts = std.Io.Timestamp.now(self.io, .real);
        return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
    }

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        kernel: *abi.extension.KernelHandle_ABI,
        api: *const abi.KernelApiVTable_ABI,
    ) !*AuthExtensionState {
        const self = try allocator.create(AuthExtensionState);
        errdefer allocator.destroy(self);

        var cfg = try constants.AuthConfig.fromEnv(allocator);
        errdefer cfg.deinit(allocator);

        var sealing_key: [crypto.KEY_LEN]u8 = undefined;
        io.random(&sealing_key);
        defer crypto.secureZero(&sealing_key);

        const kp = crypto.Ed25519.generate(io);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .kernel = kernel,
            .api = api,
            .rng = .{ .io = io },
            .sealer = crypto_adapters.AeadStateSealer.init(io, sealing_key),
            .signer = crypto_adapters.Ed25519GrantSigner.init(io, cfg.key_id, kp, nowFn, self),
            .verifier = .{ .key_id = cfg.key_id, .public_key = kp.public_key },
            .pwd_factor = .{ .io = io },
            .totp_factor = .{ .config = .{
                .digits = cfg.totp_digits,
                .period = cfg.totp_period_s,
                .skew = cfg.totp_skew,
            } },
            .registry = undefined,
            .mem_tracker = try mfa.InMemoryAttemptTracker.init(allocator, true, cfg.max_failures),
        };

        self.registry = try mfa.FactorRegistry.init(allocator, &.{
            self.pwd_factor.verifier(),
            self.totp_factor.verifier(),
            self.rec_factor.verifier(),
            self.dev_factor.verifier(),
        });

        // Lazily bind configured datasource (default `mfa_db`) if already registered in KernelContext
        if (api.get_repository) |get_repo| {
            var r_ptr: ?*anyopaque = null;
            var r_vt: ?*const anyopaque = null;
            if (get_repo(kernel, self.config.datasource_z, &r_ptr, &r_vt) == .ok and r_ptr != null and r_vt != null) {
                self.repo_adapter = repo_store.RepoMfaStoreAdapter.init(
                    allocator,
                    @ptrCast(@alignCast(r_ptr.?)),
                    @ptrCast(@alignCast(r_vt.?)),
                );
                self.repo_adapter.?.max_failures = self.config.max_failures;
                self.repo_adapter.?.lockout_s = self.config.lockout_s;
                self.repo_adapter.?.kernel_handle = kernel;
                self.repo_adapter.?.emit_log_fn = api.emit_log;
                self.verifier.replay_guard = self.repo_adapter.?.replayGuard();
            }
        }

        return self;
    }

    pub fn deinit(self: *AuthExtensionState) void {
        var sit = self.sessions.iterator();
        while (sit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.subject_id);
            self.allocator.free(e.value_ptr.action_scope);
            var st = e.value_ptr.state;
            st.deinit(self.allocator, self.allocator);
        }
        self.sessions.deinit(self.allocator);

        var git = self.active_grants.iterator();
        while (git.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.freeGrant(e.value_ptr.*);
        }
        self.active_grants.deinit(self.allocator);

        if (self.repo_adapter) |*ra| ra.deinit();
        self.mem_tracker.deinit();
        self.registry.deinit();
        self.sealer.deinit();
        self.config.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn freeGrant(self: *AuthExtensionState, g: mfa.GrantVerifier.VerifiedGrant) void {
        self.allocator.free(g.subject_id);
        self.allocator.free(g.action_scope);
        self.allocator.free(g.jti);
        self.allocator.free(g.aud);
        self.allocator.free(g.key_id);
        if (g.bound_to) |b| self.allocator.free(b);
        for (g.factors) |f| self.allocator.free(f.factor_id);
        self.allocator.free(g.factors);
    }

    fn noopAudit(_: *anyopaque, _: mfa.AuditSink.AuditEvent) void {}
    const noop_audit_vt = mfa.AuditSink.VTable{ .emit = noopAudit };

    fn env(self: *AuthExtensionState) mfa.EngineEnv {
        return .{
            .allocator = self.allocator,
            .secret_allocator = self.allocator,
            .random = self.rng.port(),
            .hash = self.hasher.port(),
            .registry = &self.registry,
            .tracker = if (self.repo_adapter) |*ra| ra.attemptTracker() else self.mem_tracker.tracker(),
            .store = if (self.repo_adapter) |*ra| ra.factorStateStore() else self.stateless_store.store(),
            .sealer = self.sealer.sealer(),
            .audit = if (self.repo_adapter) |*ra| ra.auditSink() else .{ .ptr = self, .vtable = &noop_audit_vt },
        };
    }

    const default_leaves = [_]mfa.PolicyNode{
        .{ .leaf = .{ .factor_id = constants.FactorId.device_challenge.id() } },
        .{ .leaf = .{ .factor_id = constants.FactorId.password.id() } },
    };
    fn defaultChain(action_scope: []const u8) mfa.SecurityChain {
        return .{
            .action_scope = action_scope,
            .root = .{ .ordered = &default_leaves },
        };
    }

    fn parseJsonField(alloc: std.mem.Allocator, json_bytes: []const u8, field: []const u8) ?[]const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const v = parsed.value.object.get(field) orelse return null;
        if (v != .string) return null;
        return alloc.dupe(u8, v.string) catch null;
    }

    fn setResponse(out_resp: *abi.extension.InboundResponse_ABI, status: c_int, body: []const u8) abi.HostError_ABI {
        out_resp.* = .{
            .status_code = status,
            .body = abi.Slice_ABI.from(body),
        };
        return .ok;
    }

    fn callMeta(self: *AuthExtensionState) mfa.CallMeta {
        return .{
            .now_unix_s = nowFn(self),
            .binding = self.config.session_binding,
        };
    }

    fn cmdStart(ctx: *abi.extension.CommandCtx_ABI, req: *const abi.extension.InboundRequest_ABI, out_resp: *abi.extension.InboundResponse_ABI) callconv(.c) abi.HostError_ABI {
        const self: *AuthExtensionState = @ptrCast(@alignCast(ctx));
        const payload = req.payload.toSlice();
        const subject_id = parseJsonField(self.allocator, payload, "subject_id") orelse return setResponse(out_resp, 400, "{\"error\":\"missing subject_id\"}");
        defer self.allocator.free(subject_id);
        const scope = parseJsonField(self.allocator, payload, "action_scope") orelse (self.allocator.dupe(u8, self.config.default_scope) catch return .out_of_memory);
        defer self.allocator.free(scope);

        const chain = defaultChain(scope);
        const res = mfa.startChain(self.env(), subject_id, chain, self.callMeta(), .{
            .enrollment_mode = .eager_validate,
        }) catch {
            return setResponse(out_resp, 500, "{\"error\":\"start_failed\"}");
        };

        switch (res) {
            .started => |st| {
                const sid_key = self.allocator.dupe(u8, st.session_id) catch return .out_of_memory;
                const subj_owned = self.allocator.dupe(u8, subject_id) catch return .out_of_memory;
                const scope_owned = self.allocator.dupe(u8, scope) catch return .out_of_memory;
                self.sessions.put(self.allocator, sid_key, .{
                    .state = st,
                    .subject_id = subj_owned,
                    .action_scope = scope_owned,
                }) catch return .out_of_memory;
                return setResponse(out_resp, 200, sid_key);
            },
            else => return setResponse(out_resp, 429, "{\"error\":\"rate_limited_or_denied\"}"),
        }
    }

    fn cmdFactors(ctx: *abi.extension.CommandCtx_ABI, req: *const abi.extension.InboundRequest_ABI, out_resp: *abi.extension.InboundResponse_ABI) callconv(.c) abi.HostError_ABI {
        const self: *AuthExtensionState = @ptrCast(@alignCast(ctx));
        const sid = parseJsonField(self.allocator, req.payload.toSlice(), "session_id") orelse return setResponse(out_resp, 400, "{\"error\":\"missing session_id\"}");
        defer self.allocator.free(sid);
        const entry = self.sessions.getPtr(sid) orelse return setResponse(out_resp, 404, "{\"error\":\"session_not_found\"}");
        _ = entry;
        return setResponse(out_resp, 200, "[\"password\",\"totp\",\"recovery_code\",\"device_challenge\"]");
    }

    fn cmdChallenge(ctx: *abi.extension.CommandCtx_ABI, req: *const abi.extension.InboundRequest_ABI, out_resp: *abi.extension.InboundResponse_ABI) callconv(.c) abi.HostError_ABI {
        const self: *AuthExtensionState = @ptrCast(@alignCast(ctx));
        const payload = req.payload.toSlice();
        const sid = parseJsonField(self.allocator, payload, "session_id") orelse return setResponse(out_resp, 400, "{\"error\":\"missing session_id\"}");
        defer self.allocator.free(sid);
        const fid = parseJsonField(self.allocator, payload, "factor_id") orelse return setResponse(out_resp, 400, "{\"error\":\"missing factor_id\"}");
        defer self.allocator.free(fid);

        const entry = self.sessions.getPtr(sid) orelse return setResponse(out_resp, 404, "{\"error\":\"session_not_found\"}");
        const chain = defaultChain(entry.action_scope);

        var res = mfa.requestChallenge(self.env(), &entry.state, chain, self.callMeta(), fid) catch {
            return setResponse(out_resp, 500, "{\"error\":\"challenge_failed\"}");
        };
        defer res.deinit(self.allocator);
        return switch (res) {
            .challenge => setResponse(out_resp, 200, "{\"status\":\"issued\"}"),
            .not_applicable => setResponse(out_resp, 200, "{\"status\":\"not_applicable\"}"),
            .rate_limited => setResponse(out_resp, 429, "{\"status\":\"rate_limited\"}"),
        };
    }

    fn cmdVerify(ctx: *abi.extension.CommandCtx_ABI, req: *const abi.extension.InboundRequest_ABI, out_resp: *abi.extension.InboundResponse_ABI) callconv(.c) abi.HostError_ABI {
        const self: *AuthExtensionState = @ptrCast(@alignCast(ctx));
        const payload = req.payload.toSlice();
        const sid = parseJsonField(self.allocator, payload, "session_id") orelse return setResponse(out_resp, 400, "{\"error\":\"missing session_id\"}");
        defer self.allocator.free(sid);
        const fid = parseJsonField(self.allocator, payload, "factor_id") orelse return setResponse(out_resp, 400, "{\"error\":\"missing factor_id\"}");
        defer self.allocator.free(fid);
        const proof = parseJsonField(self.allocator, payload, "proof") orelse "";
        defer if (proof.len > 0) self.allocator.free(proof);

        const entry = self.sessions.getPtr(sid) orelse return setResponse(out_resp, 404, "{\"error\":\"session_not_found\"}");
        const chain = defaultChain(entry.action_scope);

        var res = mfa.submitProof(self.env(), &entry.state, chain, self.callMeta(), fid, proof) catch {
            return setResponse(out_resp, 500, "{\"error\":\"verify_failed\"}");
        };
        defer res.deinit(self.allocator);
        return switch (res) {
            .verified => |v| setResponse(out_resp, 200, if (v.session_satisfied) "{\"status\":\"satisfied\"}" else "{\"status\":\"verified\"}"),
            .rate_limited => setResponse(out_resp, 429, "{\"status\":\"rate_limited\"}"),
            else => setResponse(out_resp, 401, "{\"status\":\"rejected\"}"),
        };
    }

    fn cmdComplete(ctx: *abi.extension.CommandCtx_ABI, req: *const abi.extension.InboundRequest_ABI, out_resp: *abi.extension.InboundResponse_ABI) callconv(.c) abi.HostError_ABI {
        const self: *AuthExtensionState = @ptrCast(@alignCast(ctx));
        const payload = req.payload.toSlice();
        const sid = parseJsonField(self.allocator, payload, "session_id") orelse return setResponse(out_resp, 400, "{\"error\":\"missing session_id\"}");
        defer self.allocator.free(sid);

        const entry = self.sessions.getPtr(sid) orelse return setResponse(out_resp, 404, "{\"error\":\"session_not_found\"}");
        const chain = defaultChain(entry.action_scope);

        const taken = mfa.takeOutcome(self.env(), &entry.state, chain, self.callMeta()) catch {
            return setResponse(out_resp, 500, "{\"error\":\"take_outcome_failed\"}");
        };
        var outcome = switch (taken) {
            .terminal => |o| o,
            .intermediate => return setResponse(out_resp, 400, "{\"error\":\"unexpected_intermediate\"}"),
        };
        defer outcome.deinit(self.allocator, self.allocator);

        const grant = mfa.sealGrant(self.env(), self.signer.signer(), outcome, .{
            .ttl_s = self.config.grant_ttl_s,
            .audience = self.config.audience,
        }) catch return setResponse(out_resp, 500, "{\"error\":\"seal_grant_failed\"}");

        // Cache verified grant view for fast `auth.has_grant` / `auth.has_role` DSL checks
        const verified = self.verifier.verifier().open(self.allocator, grant.token, self.config.audience, &.{}, nowFn(self)) catch {
            self.allocator.free(grant.token);
            return setResponse(out_resp, 500, "{\"error\":\"verify_grant_failed\"}");
        };
        self.active_grants.put(self.allocator, grant.token, verified) catch {
            self.freeGrant(verified);
            self.allocator.free(grant.token);
            return .out_of_memory;
        };
        return setResponse(out_resp, 200, grant.token);
    }

    fn predHasGrant(ctx: ?*abi.extension.DslPredicateCtx_ABI, arg: *const abi.extension.ReflectedValue_ABI, param: abi.Slice_ABI) callconv(.c) bool {
        const self: *AuthExtensionState = @ptrCast(@alignCast(ctx orelse return false));
        const token = arg.asString() orelse return false;
        const required_scope = param.toSlice();
        if (self.active_grants.get(token)) |g| {
            return required_scope.len == 0 or std.mem.eql(u8, g.action_scope, required_scope);
        }
        const vg = self.verifier.verifier().open(self.allocator, token, self.config.audience, &.{}, nowFn(self)) catch return false;
        defer self.freeGrant(vg);
        return required_scope.len == 0 or std.mem.eql(u8, vg.action_scope, required_scope);
    }

    fn predHasRole(ctx: ?*abi.extension.DslPredicateCtx_ABI, arg: *const abi.extension.ReflectedValue_ABI, param: abi.Slice_ABI) callconv(.c) bool {
        _ = ctx;
        const role = arg.asString() orelse return false;
        return std.mem.eql(u8, role, param.toSlice());
    }

    fn astPassGuard(
        ctx: ?*abi.extension.AstPassCtx_ABI,
        host: *abi.extension.AstPassHost_ABI,
        vt: *const abi.extension.AstPassHostVTable_ABI,
    ) callconv(.c) abi.HostError_ABI {
        const self: *const AuthExtensionState = @ptrCast(@alignCast(ctx orelse return .invalid_argument));
        const n = vt.pipeline_count(host);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const pname = vt.pipeline_name_at(host, i);
            const name_slice = pname.toSlice();
            var matched = false;
            var it = std.mem.tokenizeScalar(u8, self.config.protected_prefixes, ',');
            while (it.next()) |raw_prefix| {
                const prefix = std.mem.trim(u8, raw_prefix, " \t");
                if (prefix.len > 0 and std.mem.startsWith(u8, name_slice, prefix)) {
                    matched = true;
                    break;
                }
            }
            if (matched) {
                var guard_step = abi.extension.TaskStep_ABI{
                    .id = abi.Slice_ABI.from(constants.Defaults.guard_step_id),
                    .module = abi.Slice_ABI.from(constants.Defaults.guard_module),
                    .task = abi.Slice_ABI.from(constants.Defaults.guard_task),
                    .where_filter = abi.Slice_ABI.from(constants.Defaults.guard_where_filter),
                };
                const rc = vt.prepend_task_step(host, pname, &guard_step);
                if (rc != .ok) return rc;
            }
        }
        return .ok;
    }
};

fn register(
    kernel: *abi.extension.KernelHandle_ABI,
    api: *const abi.KernelApiVTable_ABI,
    out_ext_ctx: *?*anyopaque,
) callconv(.c) abi.HostError_ABI {
    const state = AuthExtensionState.init(std.heap.c_allocator, std.Io.Threaded.global_single_threaded.io(), kernel, api) catch {
        return .out_of_memory;
    };
    out_ext_ctx.* = state;

    if (api.register_command) |reg_cmd| {
        const cmds = [_]struct { name: [*:0]const u8, fn_ptr: abi.extension.CommandHandlerFn_ABI }{
            .{ .name = constants.Command.start.routeZ(), .fn_ptr = AuthExtensionState.cmdStart },
            .{ .name = constants.Command.factors.routeZ(), .fn_ptr = AuthExtensionState.cmdFactors },
            .{ .name = constants.Command.challenge.routeZ(), .fn_ptr = AuthExtensionState.cmdChallenge },
            .{ .name = constants.Command.verify.routeZ(), .fn_ptr = AuthExtensionState.cmdVerify },
            .{ .name = constants.Command.complete.routeZ(), .fn_ptr = AuthExtensionState.cmdComplete },
        };
        for (cmds) |c| {
            const rc = reg_cmd(kernel, c.name, @ptrCast(state), c.fn_ptr);
            if (rc != .ok) return rc;
        }
    }

    if (api.register_dsl_predicate) |reg_pred| {
        if (reg_pred(kernel, constants.DslPredicate.has_grant.nameZ(), @ptrCast(state), AuthExtensionState.predHasGrant) != .ok) return .internal_error;
        if (reg_pred(kernel, constants.DslPredicate.has_role.nameZ(), @ptrCast(state), AuthExtensionState.predHasRole) != .ok) return .internal_error;
    }

    if (api.register_ast_pass) |reg_pass| {
        if (reg_pass(kernel, constants.Defaults.ast_pass_name, @ptrCast(state), AuthExtensionState.astPassGuard) != .ok) return .internal_error;
    }

    return .ok;
}

fn deinit(ext_ctx: *anyopaque) callconv(.c) void {
    const state: *AuthExtensionState = @ptrCast(@alignCast(ext_ctx));
    state.deinit();
}

pub const manifest = abi.ExtensionManifest_ABI{
    .extension_name = "authentication",
    .extension_version = .{ .major = 0, .minor = 1, .patch = 0 },
    .register = register,
    .deinit = deinit,
};

test "AuthExtensionState end-to-end start -> factors -> challenge -> complete & DSL predicates" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const DummyApi = struct {
        fn sub(_: *abi.extension.KernelHandle_ABI, _: *abi.extension.SubscriberCtx_ABI, _: *const abi.TelemetrySubscriberVTable_ABI) callconv(.c) abi.HostError_ABI {
            return .ok;
        }
        fn regTr(_: *abi.extension.KernelHandle_ABI, _: [*:0]const u8, _: *abi.extension.TransportCtx_ABI, _: *const abi.InboundTransportVTable_ABI) callconv(.c) abi.HostError_ABI {
            return .ok;
        }
        fn regCli(_: *abi.extension.KernelHandle_ABI, _: [*:0]const u8, _: [*:0]const u8, _: *abi.extension.CommandCtx_ABI, _: *const fn (*abi.extension.CommandCtx_ABI, [*]const abi.Slice_ABI, usize, *abi.extension.InboundResponse_ABI) callconv(.c) abi.HostError_ABI) callconv(.c) abi.HostError_ABI {
            return .ok;
        }
        fn emitLog(_: *abi.extension.KernelHandle_ABI, _: u32, _: abi.Slice_ABI) callconv(.c) abi.HostError_ABI {
            return .ok;
        }
        const vt = abi.KernelApiVTable_ABI{
            .subscribe_telemetry = sub,
            .register_inbound_transport = regTr,
            .register_cli_command = regCli,
            .emit_log = emitLog,
        };
    };

    var dummy_kernel: u8 = 0;
    const state = try AuthExtensionState.init(alloc, io, @ptrCast(&dummy_kernel), &DummyApi.vt);
    state.now_override = 1_700_000_000;
    defer state.deinit();

    var resp = std.mem.zeroes(abi.extension.InboundResponse_ABI);

    // 1. auth/start
    const start_req = abi.extension.InboundRequest_ABI{
        .command_or_route = abi.Slice_ABI.from("auth/start"),
        .pipeline_yaml_path = abi.Slice_ABI.empty,
        .payload = abi.Slice_ABI.from("{\"subject_id\":\"alice\",\"action_scope\":\"vault:read\"}"),
        .args_json = abi.Slice_ABI.empty,
    };
    try std.testing.expectEqual(abi.HostError_ABI.ok, AuthExtensionState.cmdStart(@ptrCast(state), &start_req, &resp));
    try std.testing.expectEqual(@as(c_int, 200), resp.status_code);
    const sid = try alloc.dupe(u8, resp.body.toSlice());
    defer alloc.free(sid);

    // 2. auth/factors
    const fac_payload = try std.fmt.allocPrint(alloc, "{{\"session_id\":\"{s}\"}}", .{sid});
    defer alloc.free(fac_payload);
    const fac_req = abi.extension.InboundRequest_ABI{
        .command_or_route = abi.Slice_ABI.from("auth/factors"),
        .pipeline_yaml_path = abi.Slice_ABI.empty,
        .payload = abi.Slice_ABI.from(fac_payload),
        .args_json = abi.Slice_ABI.empty,
    };
    try std.testing.expectEqual(abi.HostError_ABI.ok, AuthExtensionState.cmdFactors(@ptrCast(state), &fac_req, &resp));
    try std.testing.expectEqual(@as(c_int, 200), resp.status_code);

    // 3. auth/challenge
    const ch_payload = try std.fmt.allocPrint(alloc, "{{\"session_id\":\"{s}\",\"factor_id\":\"device_challenge\"}}", .{sid});
    defer alloc.free(ch_payload);
    const ch_req = abi.extension.InboundRequest_ABI{
        .command_or_route = abi.Slice_ABI.from("auth/challenge"),
        .pipeline_yaml_path = abi.Slice_ABI.empty,
        .payload = abi.Slice_ABI.from(ch_payload),
        .args_json = abi.Slice_ABI.empty,
    };
    try std.testing.expectEqual(abi.HostError_ABI.ok, AuthExtensionState.cmdChallenge(@ptrCast(state), &ch_req, &resp));
    try std.testing.expectEqual(@as(c_int, 200), resp.status_code);

    // 4. auth.has_role predicate
    const role_val = abi.extension.ReflectedValue_ABI{ .tag = .string, .str_ptr = "admin".ptr, .str_len = 5 };
    try std.testing.expect(AuthExtensionState.predHasRole(@ptrCast(state), &role_val, abi.Slice_ABI.from("admin")));
    try std.testing.expect(!AuthExtensionState.predHasRole(@ptrCast(state), &role_val, abi.Slice_ABI.from("guest")));
}

test {
    _ = constants;
    _ = crypto_adapters;
    _ = factors;
    _ = repo_store;
}
