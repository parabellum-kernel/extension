const std = @import("std");
const crypto = @import("parabellum_crypto");
const mfa = @import("parabellum_mfa");

/// `mfa.RandomPort` backed by `std.Io.random`.
pub const CryptoRandomPort = struct {
    io: std.Io,

    pub fn port(self: *CryptoRandomPort) mfa.RandomPort {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn bytes(ctx: *anyopaque, out: []u8) mfa.RandomPort.RandomError!void {
        const self: *CryptoRandomPort = @ptrCast(@alignCast(ctx));
        self.io.random(out);
    }

    const vtable = mfa.RandomPort.VTable{ .bytes = bytes };
};

/// `mfa.HashPort` backed by `parabellum_crypto.Sha256`.
pub const Sha256HashPort = struct {
    pub fn port(self: *Sha256HashPort) mfa.HashPort {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn algorithmId(_: *anyopaque) []const u8 {
        return "sha256";
    }

    fn hash(_: *anyopaque, parts: []const []const u8) [32]u8 {
        var h = crypto.Sha256.init();
        for (parts) |p| h.update(p);
        return h.final();
    }

    const vtable = mfa.HashPort.VTable{
        .algorithmId = algorithmId,
        .hash = hash,
    };
};

/// `mfa.StateSealer` backed by `parabellum_crypto.XChaCha20Poly1305` (`encryptBlobWithNonce` / `decryptBlobWithNonce`).
pub const AeadStateSealer = struct {
    key: crypto.SecretBytes(crypto.KEY_LEN),
    io: std.Io,

    pub fn init(io: std.Io, key_bytes: [crypto.KEY_LEN]u8) AeadStateSealer {
        return .{
            .key = crypto.SecretBytes(crypto.KEY_LEN).init(key_bytes),
            .io = io,
        };
    }

    pub fn deinit(self: *AeadStateSealer) void {
        self.key.deinit();
    }

    pub fn sealer(self: *AeadStateSealer) mfa.StateSealer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn seal(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        random: mfa.RandomPort,
        plaintext: []const u8,
        aad: []const u8,
    ) mfa.StateSealer.SealerError![]u8 {
        const self: *AeadStateSealer = @ptrCast(@alignCast(ctx));
        const out = allocator.alloc(u8, crypto.XCHACHA_NONCE_LEN + plaintext.len + crypto.TAG_LEN) catch return error.OutOfMemory;
        errdefer allocator.free(out);

        var nonce: [crypto.XCHACHA_NONCE_LEN]u8 = undefined;
        random.bytes(&nonce) catch return error.SealFailed;
        @memcpy(out[0..crypto.XCHACHA_NONCE_LEN], &nonce);

        var tag: [crypto.TAG_LEN]u8 = undefined;
        crypto.XChaCha20Poly1305.encrypt(
            out[crypto.XCHACHA_NONCE_LEN..][0..plaintext.len],
            &tag,
            plaintext,
            aad,
            nonce,
            self.key.bytes().*,
        );
        @memcpy(out[crypto.XCHACHA_NONCE_LEN + plaintext.len ..][0..crypto.TAG_LEN], &tag);
        return out;
    }

    fn open(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        blob: []const u8,
        aad: []const u8,
    ) mfa.StateSealer.SealerError![]u8 {
        const self: *AeadStateSealer = @ptrCast(@alignCast(ctx));
        return crypto.decryptBlobWithNonce(allocator, self.key.bytes().*, blob, aad) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OpenFailed,
        };
    }

    const vtable = mfa.StateSealer.VTable{
        .seal = seal,
        .open = open,
    };
};

const GRANT_MAGIC: [4]u8 = .{ 'P', 'B', 'G', '1' };

/// `mfa.GrantSigner` using `parabellum_crypto.Ed25519` + `Base64Url`.
/// Wire format (before Base64Url): `payload || signature[64]`, where `payload` is encoded via `BinaryWriter`.
pub const Ed25519GrantSigner = struct {
    io: std.Io,
    key_id: []const u8,
    key_pair: crypto.Ed25519.KeyPair,
    now_fn: *const fn (ctx: ?*anyopaque) i64,
    now_ctx: ?*anyopaque = null,

    pub fn init(
        io: std.Io,
        key_id: []const u8,
        key_pair: crypto.Ed25519.KeyPair,
        now_fn: *const fn (ctx: ?*anyopaque) i64,
        now_ctx: ?*anyopaque,
    ) Ed25519GrantSigner {
        return .{
            .io = io,
            .key_id = key_id,
            .key_pair = key_pair,
            .now_fn = now_fn,
            .now_ctx = now_ctx,
        };
    }

    pub fn signer(self: *Ed25519GrantSigner) mfa.GrantSigner {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn seal(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        outcome: *const mfa.ChainOutcome,
        grant_spec: mfa.GrantSigner.GrantSpec,
    ) mfa.GrantSigner.SignerError![]u8 {
        const self: *Ed25519GrantSigner = @ptrCast(@alignCast(ctx));

        var jti_raw: [16]u8 = undefined;
        self.io.random(&jti_raw);
        var jti_hex: [32]u8 = undefined;
        const jti_slice = std.fmt.bytesToHex(jti_raw, .lower);
        @memcpy(&jti_hex, &jti_slice);

        const iat: i64 = self.now_fn(self.now_ctx);
        const ttl_i64: i64 = @intCast(@min(grant_spec.ttl_s, @as(u64, std.math.maxInt(i64))));
        const exp: i64 = iat +| ttl_i64;

        var w = crypto.BinaryWriter.init(allocator);
        defer w.deinit();

        w.writeBytes(&GRANT_MAGIC) catch return error.OutOfMemory;
        w.writeSlice(self.key_id) catch return error.OutOfMemory;
        w.writeSlice(outcome.subject_id) catch return error.OutOfMemory;
        w.writeSlice(outcome.action_scope) catch return error.OutOfMemory;
        w.writeBytes(&outcome.policy_fingerprint) catch return error.OutOfMemory;
        w.writeSlice(&jti_hex) catch return error.OutOfMemory;
        w.writeInt(i64, iat) catch return error.OutOfMemory;
        w.writeInt(i64, exp) catch return error.OutOfMemory;
        w.writeSlice(grant_spec.audience) catch return error.OutOfMemory;
        w.writeU8(@bitCast(outcome.categories_mask)) catch return error.OutOfMemory;
        w.writeOptSlice(grant_spec.bound_to) catch return error.OutOfMemory;

        const f_count: u16 = @intCast(@min(outcome.satisfied_factors.len, std.math.maxInt(u16)));
        w.writeInt(u16, f_count) catch return error.OutOfMemory;
        for (outcome.satisfied_factors[0..f_count]) |f| {
            w.writeSlice(f.factor_id) catch return error.OutOfMemory;
            w.writeInt(i64, f.verified_at) catch return error.OutOfMemory;
            w.writeBool(f.contributing) catch return error.OutOfMemory;
        }

        const payload = w.buf.items;
        const sig = crypto.Ed25519.sign(self.key_pair, payload) catch return error.SignFailed;
        const sig_bytes = sig.toBytes();

        const raw_token = allocator.alloc(u8, payload.len + sig_bytes.len) catch return error.OutOfMemory;
        defer {
            crypto.secureZero(raw_token);
            allocator.free(raw_token);
        }
        @memcpy(raw_token[0..payload.len], payload);
        @memcpy(raw_token[payload.len..], &sig_bytes);

        return crypto.Base64Url.encodeAlloc(allocator, raw_token) catch return error.OutOfMemory;
    }

    const vtable = mfa.GrantSigner.VTable{ .seal = seal };
};

/// `mfa.GrantVerifier` verifying `Ed25519` signed grants, audience, policy fingerprint, expiry, and replay.
pub const Ed25519GrantVerifier = struct {
    key_id: []const u8,
    public_key: crypto.Ed25519.PublicKey,
    replay_guard: ?mfa.ReplayGuard = null,

    pub fn verifier(self: *Ed25519GrantVerifier) mfa.GrantVerifier {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn open(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        token: []const u8,
        expected_audience: []const u8,
        expected_policies: []const [32]u8,
        now_unix_s: i64,
    ) mfa.GrantVerifier.VerifyError!mfa.GrantVerifier.VerifiedGrant {
        const self: *Ed25519GrantVerifier = @ptrCast(@alignCast(ctx));

        const raw = crypto.Base64Url.decodeAlloc(allocator, token) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSignature,
        };
        defer allocator.free(raw);

        if (raw.len < 4 + crypto.Ed25519.signature_length) return error.InvalidGrant;
        const payload = raw[0 .. raw.len - crypto.Ed25519.signature_length];
        const sig_bytes: [crypto.Ed25519.signature_length]u8 = raw[payload.len..][0..crypto.Ed25519.signature_length].*;
        const sig = crypto.Ed25519.Signature.fromBytes(sig_bytes);

        var r = crypto.BinaryReader.init(payload);
        const magic = r.readBytes(4) catch return error.InvalidGrant;
        if (!std.mem.eql(u8, &magic, &GRANT_MAGIC)) return error.InvalidGrant;

        const kid = r.readSlice(allocator) catch return error.InvalidGrant;
        errdefer allocator.free(kid);
        if (!std.mem.eql(u8, kid, self.key_id)) {
            allocator.free(kid);
            return error.UnknownKeyId;
        }

        // Verify signature before trusting any remaining fields
        if (!crypto.Ed25519.verify(self.public_key, payload, sig)) {
            allocator.free(kid);
            return error.InvalidSignature;
        }

        const subject_id = r.readSlice(allocator) catch return error.InvalidGrant;
        errdefer allocator.free(subject_id);
        const action_scope = r.readSlice(allocator) catch return error.InvalidGrant;
        errdefer allocator.free(action_scope);
        const policy_fp = r.readBytes(32) catch return error.InvalidGrant;
        const jti = r.readSlice(allocator) catch return error.InvalidGrant;
        errdefer allocator.free(jti);
        const iat = r.readInt(i64) catch return error.InvalidGrant;
        const exp = r.readInt(i64) catch return error.InvalidGrant;
        const aud = r.readSlice(allocator) catch return error.InvalidGrant;
        errdefer allocator.free(aud);
        const cat_mask = r.readU8() catch return error.InvalidGrant;
        const bound_slice = r.readOptSlice(allocator) catch return error.InvalidGrant;
        errdefer if (bound_slice) |b| allocator.free(b);

        const f_count = r.readInt(u16) catch return error.InvalidGrant;
        const factors = allocator.alloc(mfa.GrantVerifier.VerifiedFactor, f_count) catch return error.OutOfMemory;
        var f_init: usize = 0;
        errdefer {
            for (factors[0..f_init]) |f| allocator.free(f.factor_id);
            allocator.free(factors);
        }
        for (0..f_count) |i| {
            const fid = r.readSlice(allocator) catch return error.InvalidGrant;
            const vat = r.readInt(i64) catch return error.InvalidGrant;
            const contrib = r.readBool() catch return error.InvalidGrant;
            factors[i] = .{
                .factor_id = fid,
                .verified_at = vat,
                .contributing = contrib,
            };
            f_init += 1;
        }
        if (r.remaining() != 0) return error.InvalidGrant;

        if (!std.mem.eql(u8, aud, expected_audience)) return error.InvalidAudience;

        if (expected_policies.len > 0) {
            var policy_ok = false;
            for (expected_policies) |ep| {
                if (crypto.ctEql32(&ep, &policy_fp)) {
                    policy_ok = true;
                    break;
                }
            }
            if (!policy_ok) return error.PolicyMismatch;
        }

        if (now_unix_s >= exp) return error.Expired;

        if (self.replay_guard) |rg| {
            const status = rg.markUsed(jti, exp) catch return error.InvalidGrant;
            if (status == .replayed) return error.ReplayedGrant;
        }

        return .{
            .subject_id = subject_id,
            .action_scope = action_scope,
            .policy_fingerprint = policy_fp,
            .jti = jti,
            .iat = iat,
            .exp = exp,
            .aud = aud,
            .key_id = kid,
            .categories_mask = @bitCast(cat_mask),
            .bound_to = bound_slice,
            .factors = factors,
        };
    }

    const vtable = mfa.GrantVerifier.VTable{ .open = open };
};

test "lib/mfa conformance suites pass for crypto adapters" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var rng = CryptoRandomPort{ .io = io };
    var hasher = Sha256HashPort{};
    var sealer = AeadStateSealer.init(io, @splat(0x55));
    defer sealer.deinit();

    try mfa.testing.random_sanity(rng.port());
    try mfa.testing.hash_conformance(hasher.port());
    try mfa.testing.sealer_conformance(sealer.sealer(), rng.port(), alloc);

    const Clock = struct {
        fn now(_: ?*anyopaque) i64 {
            return 1_700_000_000;
        }
    };
    const kp = crypto.Ed25519.generate(io);
    var signer = Ed25519GrantSigner.init(io, "k1", kp, Clock.now, null);
    var verifier = Ed25519GrantVerifier{ .key_id = "k1", .public_key = kp.public_key };
    try mfa.testing.grant_conformance(signer.signer(), verifier.verifier(), null, alloc, 1_700_000_000);
}
