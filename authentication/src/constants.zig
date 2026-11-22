const std = @import("std");

pub const Table = enum {
    mfa_subjects,
    mfa_factors,
    mfa_policies,
    mfa_factor_enrollments,
    mfa_sessions,
    mfa_attempts,
    mfa_replay_jti,
    mfa_audit_log,

    pub fn name(self: Table) []const u8 {
        return @tagName(self);
    }
};

pub const Column = enum {
    attempt_key,
    subject_id,
    factor_id,
    enrollment_id,
    session_id,
    source_key,
    fail_count,
    locked_until,
    updated_at,
    status,
    version,
    sealed_state,
    enrolled_at,
    jti,
    exp,
    event_id,
    kind,
    occurred_at,
    detail,

    pub fn nameZ(self: Column) [*:0]const u8 {
        return switch (self) {
            .attempt_key => "attempt_key",
            .subject_id => "subject_id",
            .factor_id => "factor_id",
            .enrollment_id => "enrollment_id",
            .session_id => "session_id",
            .source_key => "source_key",
            .fail_count => "fail_count",
            .locked_until => "locked_until",
            .updated_at => "updated_at",
            .status => "status",
            .version => "version",
            .sealed_state => "sealed_state",
            .enrolled_at => "enrolled_at",
            .jti => "jti",
            .exp => "exp",
            .event_id => "event_id",
            .kind => "kind",
            .occurred_at => "occurred_at",
            .detail => "detail",
        };
    }

    pub fn name(self: Column) []const u8 {
        return @tagName(self);
    }
};

pub const FactorId = enum {
    password,
    totp,
    recovery_code,
    device_challenge,

    pub fn id(self: FactorId) []const u8 {
        return @tagName(self);
    }
};

pub const Command = enum {
    start,
    factors,
    challenge,
    verify,
    complete,

    pub fn routeZ(self: Command) [*:0]const u8 {
        return switch (self) {
            .start => "auth/start",
            .factors => "auth/factors",
            .challenge => "auth/challenge",
            .verify => "auth/verify",
            .complete => "auth/complete",
        };
    }
};

pub const DslPredicate = enum {
    has_grant,
    has_role,

    pub fn nameZ(self: DslPredicate) [*:0]const u8 {
        return switch (self) {
            .has_grant => "auth.has_grant",
            .has_role => "auth.has_role",
        };
    }
};

pub const EnvVar = enum {
    PARABELLUM_AUTH_DATASOURCE,
    PARABELLUM_AUTH_AUDIENCE,
    PARABELLUM_AUTH_KEY_ID,
    PARABELLUM_AUTH_DEFAULT_SCOPE,
    PARABELLUM_AUTH_GRANT_TTL_S,
    PARABELLUM_AUTH_MAX_FAILURES,
    PARABELLUM_AUTH_LOCKOUT_S,
    PARABELLUM_AUTH_PROTECTED_PREFIXES,
    PARABELLUM_AUTH_SESSION_BINDING,
    PARABELLUM_AUTH_TOTP_PERIOD_S,
    PARABELLUM_AUTH_TOTP_SKEW,
    PARABELLUM_AUTH_TOTP_DIGITS,

    pub fn get(self: EnvVar) ?[]const u8 {
        const key: [*:0]const u8 = switch (self) {
            .PARABELLUM_AUTH_DATASOURCE => "PARABELLUM_AUTH_DATASOURCE",
            .PARABELLUM_AUTH_AUDIENCE => "PARABELLUM_AUTH_AUDIENCE",
            .PARABELLUM_AUTH_KEY_ID => "PARABELLUM_AUTH_KEY_ID",
            .PARABELLUM_AUTH_DEFAULT_SCOPE => "PARABELLUM_AUTH_DEFAULT_SCOPE",
            .PARABELLUM_AUTH_GRANT_TTL_S => "PARABELLUM_AUTH_GRANT_TTL_S",
            .PARABELLUM_AUTH_MAX_FAILURES => "PARABELLUM_AUTH_MAX_FAILURES",
            .PARABELLUM_AUTH_LOCKOUT_S => "PARABELLUM_AUTH_LOCKOUT_S",
            .PARABELLUM_AUTH_PROTECTED_PREFIXES => "PARABELLUM_AUTH_PROTECTED_PREFIXES",
            .PARABELLUM_AUTH_SESSION_BINDING => "PARABELLUM_AUTH_SESSION_BINDING",
            .PARABELLUM_AUTH_TOTP_PERIOD_S => "PARABELLUM_AUTH_TOTP_PERIOD_S",
            .PARABELLUM_AUTH_TOTP_SKEW => "PARABELLUM_AUTH_TOTP_SKEW",
            .PARABELLUM_AUTH_TOTP_DIGITS => "PARABELLUM_AUTH_TOTP_DIGITS",
        };
        const raw = std.c.getenv(key) orelse return null;
        const s = std.mem.span(raw);
        return if (s.len > 0) s else null;
    }
};

pub const Defaults = struct {
    pub const datasource: [:0]const u8 = "mfa_db";
    pub const audience: []const u8 = "parabellum";
    pub const key_id: []const u8 = "auth-k1";
    pub const default_scope: []const u8 = "vault:access";
    pub const grant_ttl_s: u64 = 3600;
    pub const max_failures: u32 = 5;
    pub const lockout_s: u64 = 300;
    pub const protected_prefixes: []const u8 = "vault,protected_";
    pub const session_binding: []const u8 = "parabellum-auth-session-binding-v1";
    pub const totp_period_s: u64 = 30;
    pub const totp_skew: u64 = 1;
    pub const totp_digits: u8 = 6;
    pub const ast_pass_name: [*:0]const u8 = "auth_guard_pass";
    pub const guard_step_id: []const u8 = "auth_grant_guard";
    pub const guard_module: []const u8 = "authentication";
    pub const guard_task: []const u8 = "verify_grant";
    pub const guard_where_filter: []const u8 = "auth.has_grant(grant)";
};

pub const AuthConfig = struct {
    datasource_z: [:0]u8,
    audience: []u8,
    key_id: []u8,
    default_scope: []u8,
    protected_prefixes: []u8,
    session_binding: []u8,
    grant_ttl_s: u64 = Defaults.grant_ttl_s,
    max_failures: u32 = Defaults.max_failures,
    lockout_s: u64 = Defaults.lockout_s,
    totp_period_s: u64 = Defaults.totp_period_s,
    totp_skew: u64 = Defaults.totp_skew,
    totp_digits: u8 = Defaults.totp_digits,

    pub fn fromEnv(allocator: std.mem.Allocator) !AuthConfig {
        const ds = EnvVar.PARABELLUM_AUTH_DATASOURCE.get() orelse Defaults.datasource;
        const aud = EnvVar.PARABELLUM_AUTH_AUDIENCE.get() orelse Defaults.audience;
        const kid = EnvVar.PARABELLUM_AUTH_KEY_ID.get() orelse Defaults.key_id;
        const scope = EnvVar.PARABELLUM_AUTH_DEFAULT_SCOPE.get() orelse Defaults.default_scope;
        const prefixes = EnvVar.PARABELLUM_AUTH_PROTECTED_PREFIXES.get() orelse Defaults.protected_prefixes;
        const binding = EnvVar.PARABELLUM_AUTH_SESSION_BINDING.get() orelse Defaults.session_binding;

        const ds_z = try allocator.dupeSentinel(u8, ds, 0);
        errdefer allocator.free(ds_z);
        const aud_d = try allocator.dupe(u8, aud);
        errdefer allocator.free(aud_d);
        const kid_d = try allocator.dupe(u8, kid);
        errdefer allocator.free(kid_d);
        const scope_d = try allocator.dupe(u8, scope);
        errdefer allocator.free(scope_d);
        const prefixes_d = try allocator.dupe(u8, prefixes);
        errdefer allocator.free(prefixes_d);
        const binding_d = try allocator.dupe(u8, binding);
        errdefer allocator.free(binding_d);

        return .{
            .datasource_z = ds_z,
            .audience = aud_d,
            .key_id = kid_d,
            .default_scope = scope_d,
            .protected_prefixes = prefixes_d,
            .session_binding = binding_d,
            .grant_ttl_s = parseIntEnv(u64, .PARABELLUM_AUTH_GRANT_TTL_S, Defaults.grant_ttl_s),
            .max_failures = parseIntEnv(u32, .PARABELLUM_AUTH_MAX_FAILURES, Defaults.max_failures),
            .lockout_s = parseIntEnv(u64, .PARABELLUM_AUTH_LOCKOUT_S, Defaults.lockout_s),
            .totp_period_s = parseIntEnv(u64, .PARABELLUM_AUTH_TOTP_PERIOD_S, Defaults.totp_period_s),
            .totp_skew = parseIntEnv(u64, .PARABELLUM_AUTH_TOTP_SKEW, Defaults.totp_skew),
            .totp_digits = parseIntEnv(u8, .PARABELLUM_AUTH_TOTP_DIGITS, Defaults.totp_digits),
        };
    }

    pub fn deinit(self: *AuthConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.datasource_z);
        allocator.free(self.audience);
        allocator.free(self.key_id);
        allocator.free(self.default_scope);
        allocator.free(self.protected_prefixes);
        allocator.free(self.session_binding);
    }

    fn parseIntEnv(comptime T: type, env_var: EnvVar, fallback: T) T {
        const s = env_var.get() orelse return fallback;
        return std.fmt.parseInt(T, s, 10) catch fallback;
    }
};

test "AuthConfig loads defaults cleanly" {
    var cfg = try AuthConfig.fromEnv(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(Defaults.datasource, cfg.datasource_z);
    try std.testing.expectEqualStrings(Defaults.audience, cfg.audience);
    try std.testing.expectEqual(Defaults.grant_ttl_s, cfg.grant_ttl_s);
    try std.testing.expectEqual(Defaults.max_failures, cfg.max_failures);
}
