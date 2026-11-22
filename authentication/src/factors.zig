const std = @import("std");
const crypto = @import("parabellum_crypto");
const otp = @import("otp");
const mfa = @import("parabellum_mfa");
const constants = @import("constants.zig");

/// Argon2id password factor (`FactorVerifier`) reading PHC hash from `factor_state` (`CR-07`).
pub const PasswordFactor = struct {
    io: std.Io,
    factor_id: []const u8 = constants.FactorId.password.id(),

    pub fn verifier(self: *PasswordFactor) mfa.FactorVerifier {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn describe(ctx: *anyopaque) mfa.FactorDescriptor {
        const self: *PasswordFactor = @ptrCast(@alignCast(ctx));
        return .{
            .factor_id = self.factor_id,
            .factor_type = "password",
            .categories = .{ .knowledge = true },
            .statefulness = .stateless,
            .is_recovery = false,
            .requires_challenge = false,
        };
    }

    fn isEnrolled(_: *anyopaque, _: []const u8) mfa.FactorVerifier.VerifierError!bool {
        return true;
    }

    fn issueChallenge(_: *anyopaque, _: mfa.FactorVerifier.ChallengeContext) mfa.FactorVerifier.VerifierError!mfa.FactorVerifier.ChallengeEmission {
        return .not_applicable;
    }

    fn verify(
        ctx: *anyopaque,
        vctx: mfa.FactorVerifier.VerifyContext,
        proof_bytes: []const u8,
    ) mfa.FactorVerifier.VerifierError!mfa.FactorVerifier.VerifyResult {
        const self: *PasswordFactor = @ptrCast(@alignCast(ctx));
        const stored_phc = vctx.factor_state orelse return .{ .status = .rejected };
        const ok = crypto.Argon2.verifyPassword(vctx.allocator, self.io, stored_phc, proof_bytes);
        return .{ .status = if (ok) .verified else .rejected };
    }

    const vtable = mfa.FactorVerifier.VTable{
        .describe = describe,
        .isEnrolled = isEnrolled,
        .issueChallenge = issueChallenge,
        .verify = verify,
    };
};

/// RFC 6238 TOTP factor (`FactorVerifier`) backed by `lib/otp`.
/// `factor_state` format: `last_step_le_u64[8] || raw_secret[...]` (or `raw_secret` on first use).
pub const TotpFactor = struct {
    factor_id: []const u8 = constants.FactorId.totp.id(),
    config: otp.TotpConfig = .{},

    pub fn verifier(self: *TotpFactor) mfa.FactorVerifier {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn describe(ctx: *anyopaque) mfa.FactorDescriptor {
        const self: *TotpFactor = @ptrCast(@alignCast(ctx));
        return .{
            .factor_id = self.factor_id,
            .factor_type = "totp",
            .categories = .{ .possession = true },
            .statefulness = .stateful,
            .is_recovery = false,
            .requires_challenge = false,
        };
    }

    fn isEnrolled(_: *anyopaque, _: []const u8) mfa.FactorVerifier.VerifierError!bool {
        return true;
    }

    fn issueChallenge(_: *anyopaque, _: mfa.FactorVerifier.ChallengeContext) mfa.FactorVerifier.VerifierError!mfa.FactorVerifier.ChallengeEmission {
        return .not_applicable;
    }

    fn verify(
        ctx: *anyopaque,
        vctx: mfa.FactorVerifier.VerifyContext,
        proof_bytes: []const u8,
    ) mfa.FactorVerifier.VerifierError!mfa.FactorVerifier.VerifyResult {
        const self: *TotpFactor = @ptrCast(@alignCast(ctx));
        const state = vctx.factor_state orelse return .{ .status = .rejected };
        if (state.len < 9) return .{ .status = .rejected };

        const last_step = std.mem.readInt(u64, state[0..8], .little);
        const secret = state[8..];

        const matched_step = (otp.verifyTotp(secret, vctx.now_unix_s, proof_bytes, self.config) catch return .{ .status = .rejected }) orelse {
            return .{ .status = .rejected };
        };
        // Reject replay of same or older TOTP time-step
        if (matched_step <= last_step and last_step != 0) {
            return .{ .status = .rejected };
        }

        const next_state = vctx.secret_allocator.alloc(u8, state.len) catch return error.OutOfMemory;
        std.mem.writeInt(u64, next_state[0..8], matched_step, .little);
        @memcpy(next_state[8..], secret);

        return .{
            .status = .verified,
            .state_update = next_state,
        };
    }

    const vtable = mfa.FactorVerifier.VTable{
        .describe = describe,
        .isEnrolled = isEnrolled,
        .issueChallenge = issueChallenge,
        .verify = verify,
    };
};

/// Single-use SHA-256 hashed recovery code factor (`is_recovery = true`).
/// `factor_state` format: concatenated 32-byte SHA-256 digests of unused recovery codes.
pub const RecoveryCodeFactor = struct {
    factor_id: []const u8 = constants.FactorId.recovery_code.id(),

    pub fn verifier(self: *RecoveryCodeFactor) mfa.FactorVerifier {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn describe(ctx: *anyopaque) mfa.FactorDescriptor {
        const self: *RecoveryCodeFactor = @ptrCast(@alignCast(ctx));
        return .{
            .factor_id = self.factor_id,
            .factor_type = "recovery_code",
            .categories = .{ .knowledge = true, .possession = true },
            .statefulness = .stateful,
            .is_recovery = true,
            .requires_challenge = false,
        };
    }

    fn isEnrolled(_: *anyopaque, _: []const u8) mfa.FactorVerifier.VerifierError!bool {
        return true;
    }

    fn issueChallenge(_: *anyopaque, _: mfa.FactorVerifier.ChallengeContext) mfa.FactorVerifier.VerifierError!mfa.FactorVerifier.ChallengeEmission {
        return .not_applicable;
    }

    fn verify(
        _: *anyopaque,
        vctx: mfa.FactorVerifier.VerifyContext,
        proof_bytes: []const u8,
    ) mfa.FactorVerifier.VerifierError!mfa.FactorVerifier.VerifyResult {
        const state = vctx.factor_state orelse return .{ .status = .rejected };
        if (state.len == 0 or (state.len % 32) != 0) return .{ .status = .rejected };

        const count = state.len / 32;
        var candidate_hash = crypto.Sha256.hash(proof_bytes);
        defer crypto.secureZero(&candidate_hash);

        var matched_idx: ?usize = null;
        for (0..count) |i| {
            const slot = state[i * 32 ..][0..32];
            if (crypto.ctEql32(&candidate_hash, slot) and matched_idx == null) {
                matched_idx = i;
            }
        }
        const idx = matched_idx orelse return .{ .status = .rejected };

        const next_state = vctx.secret_allocator.alloc(u8, (count - 1) * 32) catch return error.OutOfMemory;
        @memcpy(next_state[0 .. idx * 32], state[0 .. idx * 32]);
        @memcpy(next_state[idx * 32 ..], state[(idx + 1) * 32 ..]);

        return .{
            .status = .verified,
            .state_update = next_state,
        };
    }

    const vtable = mfa.FactorVerifier.VTable{
        .describe = describe,
        .isEnrolled = isEnrolled,
        .issueChallenge = issueChallenge,
        .verify = verify,
    };
};

/// Ed25519 device challenge-response factor (`requires_challenge = true`).
/// `factor_state` is the 32-byte Ed25519 public key; proof is the 64-byte signature over `nonce[32] || transcript[32]`.
pub const DeviceChallengeFactor = struct {
    factor_id: []const u8 = constants.FactorId.device_challenge.id(),

    pub fn verifier(self: *DeviceChallengeFactor) mfa.FactorVerifier {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn describe(ctx: *anyopaque) mfa.FactorDescriptor {
        const self: *DeviceChallengeFactor = @ptrCast(@alignCast(ctx));
        return .{
            .factor_id = self.factor_id,
            .factor_type = "device_challenge",
            .categories = .{ .possession = true },
            .statefulness = .stateless,
            .is_recovery = false,
            .requires_challenge = true,
        };
    }

    fn isEnrolled(_: *anyopaque, _: []const u8) mfa.FactorVerifier.VerifierError!bool {
        return true;
    }

    fn issueChallenge(
        _: *anyopaque,
        cctx: mfa.FactorVerifier.ChallengeContext,
    ) mfa.FactorVerifier.VerifierError!mfa.FactorVerifier.ChallengeEmission {
        const payload = cctx.allocator.alloc(u8, 64) catch return error.OutOfMemory;
        @memcpy(payload[0..32], &cctx.factor_challenge_nonce);
        @memcpy(payload[32..64], &cctx.transcript);
        return .{
            .challenge = .{
                .payload = payload,
                .ttl_s = 120,
            },
        };
    }

    fn verify(
        _: *anyopaque,
        vctx: mfa.FactorVerifier.VerifyContext,
        proof_bytes: []const u8,
    ) mfa.FactorVerifier.VerifierError!mfa.FactorVerifier.VerifyResult {
        const pk_bytes = vctx.factor_state orelse return .{ .status = .rejected };
        const nonce = vctx.factor_challenge_nonce orelse return .{ .status = .rejected };
        if (pk_bytes.len != crypto.Ed25519.public_length) return .{ .status = .rejected };
        if (proof_bytes.len != crypto.Ed25519.signature_length) return .{ .status = .rejected };

        const pk = crypto.Ed25519.PublicKey.fromBytes(pk_bytes[0..32].*) catch return .{ .status = .rejected };
        const sig = crypto.Ed25519.Signature.fromBytes(proof_bytes[0..64].*);

        var msg: [64]u8 = undefined;
        @memcpy(msg[0..32], &nonce);
        @memcpy(msg[32..64], &vctx.transcript);

        return .{ .status = if (crypto.Ed25519.verify(pk, &msg, sig)) .verified else .rejected };
    }

    const vtable = mfa.FactorVerifier.VTable{
        .describe = describe,
        .isEnrolled = isEnrolled,
        .issueChallenge = issueChallenge,
        .verify = verify,
    };
};

test "PasswordFactor, TotpFactor, RecoveryCodeFactor, DeviceChallengeFactor" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const crypto_adapters = @import("crypto_adapters.zig");
    var rng = crypto_adapters.CryptoRandomPort{ .io = io };

    // 1. PasswordFactor
    var pwd_factor = PasswordFactor{ .io = io };
    var phc_buf: [256]u8 = undefined;
    const phc = try crypto.Argon2.hashPassword(alloc, io, "s3cr3t", .{ .t = 1, .m = 32, .p = 1 }, &phc_buf);
    const pwd_ok = try pwd_factor.verifier().verify(.{
        .allocator = alloc,
        .secret_allocator = alloc,
        .random = rng.port(),
        .session_id = "s1",
        .subject_id = "u1",
        .action_scope = "login",
        .factor_id = "password",
        .transcript = @splat(0),
        .factor_state = phc,
        .enrollment_mode = .eager_validate,
        .now_unix_s = 100,
    }, "s3cr3t");
    try std.testing.expectEqual(mfa.FactorVerifier.VerifyStatus.verified, pwd_ok.status);

    // 2. TotpFactor
    var totp_factor = TotpFactor{};
    const raw_secret = "12345678901234567890";
    var totp_state: [8 + raw_secret.len]u8 = undefined;
    std.mem.writeInt(u64, totp_state[0..8], 0, .little);
    @memcpy(totp_state[8..], raw_secret);

    var code_buf: [6]u8 = undefined;
    const code = try otp.totpFormat(raw_secret, 59, .{}, &code_buf);
    const totp_res = try totp_factor.verifier().verify(.{
        .allocator = alloc,
        .secret_allocator = alloc,
        .random = rng.port(),
        .session_id = "s1",
        .subject_id = "u1",
        .action_scope = "login",
        .factor_id = "totp",
        .transcript = @splat(0),
        .factor_state = &totp_state,
        .enrollment_mode = .eager_validate,
        .now_unix_s = 59,
    }, code);
    try std.testing.expectEqual(mfa.FactorVerifier.VerifyStatus.verified, totp_res.status);
    defer if (totp_res.state_update) |su| alloc.free(su);

    // Replay same TOTP step must be rejected
    const totp_replay = try totp_factor.verifier().verify(.{
        .allocator = alloc,
        .secret_allocator = alloc,
        .random = rng.port(),
        .session_id = "s1",
        .subject_id = "u1",
        .action_scope = "login",
        .factor_id = "totp",
        .transcript = @splat(0),
        .factor_state = totp_res.state_update.?,
        .enrollment_mode = .eager_validate,
        .now_unix_s = 59,
    }, code);
    try std.testing.expectEqual(mfa.FactorVerifier.VerifyStatus.rejected, totp_replay.status);

    // 3. RecoveryCodeFactor
    var rec_factor = RecoveryCodeFactor{};
    var rec_state: [64]u8 = undefined;
    @memcpy(rec_state[0..32], &crypto.Sha256.hash("REC-1111"));
    @memcpy(rec_state[32..64], &crypto.Sha256.hash("REC-2222"));
    const rec_res = try rec_factor.verifier().verify(.{
        .allocator = alloc,
        .secret_allocator = alloc,
        .random = rng.port(),
        .session_id = "s1",
        .subject_id = "u1",
        .action_scope = "login",
        .factor_id = "recovery_code",
        .transcript = @splat(0),
        .factor_state = &rec_state,
        .enrollment_mode = .eager_validate,
        .now_unix_s = 59,
    }, "REC-1111");
    try std.testing.expectEqual(mfa.FactorVerifier.VerifyStatus.verified, rec_res.status);
    defer if (rec_res.state_update) |su| alloc.free(su);
    try std.testing.expectEqual(@as(usize, 32), rec_res.state_update.?.len);

    // 4. DeviceChallengeFactor
    var dev_factor = DeviceChallengeFactor{};
    const kp = crypto.Ed25519.generate(io);
    const nonce: [32]u8 = @splat(0xAA);
    const transcript: [32]u8 = @splat(0xBB);
    var msg: [64]u8 = undefined;
    @memcpy(msg[0..32], &nonce);
    @memcpy(msg[32..64], &transcript);
    const sig = try crypto.Ed25519.sign(kp, &msg);
    const dev_res = try dev_factor.verifier().verify(.{
        .allocator = alloc,
        .secret_allocator = alloc,
        .random = rng.port(),
        .session_id = "s1",
        .subject_id = "u1",
        .action_scope = "login",
        .factor_id = "device_challenge",
        .factor_challenge_nonce = nonce,
        .transcript = transcript,
        .factor_state = &kp.public_key.toBytes(),
        .enrollment_mode = .eager_validate,
        .now_unix_s = 59,
    }, &sig.toBytes());
    try std.testing.expectEqual(mfa.FactorVerifier.VerifyStatus.verified, dev_res.status);
}
