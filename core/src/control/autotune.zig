//! Ajuste automático dos ganhos do piloto automático, igual para qualquer avião.
//!
//! Em vez de ganhos escritos no arquivo de cada avião, o núcleo lineariza o avião no voo nivelado
//! (sim/linear.zig) e escolhe os ganhos para que as malhas internas tenham SEMPRE a mesma resposta:
//!
//!   arfagem   α̇ = Zα α + q,  q̇ = Mα α + Mq q + Mδe δe,  δe = Kae (α − αc) + Kqe q
//!             Kae para seguir 80 % do α pedido em regime (ou ω_sp ≥ 8 rad/s), Kqe para ζ = 0,65
//!   rolagem   ṗ = Lp p + Lδa δa,  δa = Kphia (φc − φ) − Kpa p          → ω = 12 rad/s, ζ = 0,9
//!   guinada   N'β = Nβ − Nδr Kbeta ≥ ω_dr² (ω_dr = 4 rad/s) — sem leme, Kbeta = 0
//!   motor     u̇ = Xthr δthr: KV = ω_V / Xthr (ω_V = 0,8 rad/s); KIV e KHT na mesma proporção
//!
//! As malhas de fora (altura → fator de carga, curso → inclinação) já são cinemáticas (não dependem
//! do avião). Derivada que não dá para usar (comando sem efeito, número absurdo) deixa o ganho
//! do arquivo como está e marca no resultado.
const std = @import("std");
const T = @import("../types.zig");
const S = @import("../sim/state.zig");
const linear = @import("../sim/linear.zig");

pub const Targets = struct {
    dc_ratio: f64 = 0.8, // fração do α pedido seguida só pelo proporcional
    sp_min: f64 = 8, // rad/s: período curto mínimo em malha fechada
    sp_zeta: f64 = 0.65,
    roll_w: f64 = 12,
    roll_zeta: f64 = 0.9,
    dr_w: f64 = 4,
    speed_w: f64 = 0.8,
};

pub const Result = extern struct {
    ok: i32 = 0, // 1: modelo linear válido
    pitch: i32 = 0, // 1: ganhos de arfagem ajustados
    roll: i32 = 0,
    yaw: i32 = 0,
    speed: i32 = 0,
    _pad: i32 = 0,
    w_sp_open: f64 = 0, // rad/s
    w_sp: f64 = 0,
};

fn good(x: f64) bool {
    return std.math.isFinite(x);
}

fn put(dst: *f64, v: f64, lo: f64, hi: f64) bool {
    if (!good(v) or v < lo or v > hi) return false;
    dst.* = v;
    return true;
}

/// ganhos a partir do modelo linear (A, B por linhas; x = u v w p q r φ θ; u = δe δa δr thr)
pub fn fromLinear(lm: *const linear.LinModel, ap: *T.Autopilot, k: Targets) Result {
    var r = Result{};
    if (lm.ok == 0 or !(lm.V > 1)) return r;
    r.ok = 1;
    const nl = linear.nl;
    const nu = linear.nu;
    const A = struct {
        fn a(m: *const linear.LinModel, i: usize, j: usize) f64 {
            return m.A[i * nl + j];
        }
        fn b(m: *const linear.LinModel, i: usize, j: usize) f64 {
            return m.B[i * nu + j];
        }
    };
    const V = lm.V;

    // ---------------- arfagem (período curto)
    const Za = A.a(lm, 2, 2);
    const Ma = A.a(lm, 4, 2) * V;
    const Mq = A.a(lm, 4, 4);
    const Mde = A.b(lm, 4, 0);
    if (good(Za) and good(Ma) and good(Mq) and good(Mde) and @abs(Mde) > 1e-3) {
        const w0sq = Za * Mq - Ma;
        r.w_sp_open = if (w0sq > 0) @sqrt(w0sq) else 0;
        // Kae: o maior entre (a) seguir o α pedido com 80 % em regime (avião muito estável precisa
        // de ganho alto: Kae = 4 Mα/Mδe) e (b) período curto de pelo menos ω_min
        const Kae_dc = if (Ma / Mde > 0) k.dc_ratio / (1 - k.dc_ratio) * Ma / Mde else 0;
        const wmin = k.sp_min;
        const Mq_min = -2 * k.sp_zeta * wmin - Za;
        const Kae_w = ((Za * Mq_min - wmin * wmin) - Ma) / Mde;
        const Kae = @max(Kae_dc, Kae_w);
        // com Mα' fixo, ω e M'q saem de: ω² + 2ζZα ω + Zα² + M'α = 0 e M'q = −2ζω − Zα
        const Ma2 = Ma + Mde * Kae;
        const disc = k.sp_zeta * k.sp_zeta * Za * Za - Za * Za - Ma2;
        if (good(Kae) and Kae > 0 and Kae < 50 and disc > 0) {
            const w = -k.sp_zeta * Za + @sqrt(disc);
            const Mq2 = -2 * k.sp_zeta * w - Za;
            const Kqe = @max(0, (Mq2 - Mq) / Mde); // o avião já amortece o bastante: 0
            if (good(w) and good(Kqe) and Kqe < 10) {
                ap.Kae = Kae;
                ap.Kqe = Kqe;
                ap.KIa = Kae; // integral do erro de α (tira o resto do erro em regime)
                ap.Kthe = Kae * 0.375; // no chão depois do pouso (segura θ): mesma proporção do padrão
                r.w_sp = w;
                r.pitch = 1;
            }
        }
    }

    // ---------------- rolagem
    const Lp = A.a(lm, 3, 3);
    const Lda = A.b(lm, 3, 1);
    if (good(Lp) and good(Lda) and @abs(Lda) > 1e-3) {
        const w = k.roll_w;
        const Kphia = w * w / Lda;
        const Kpa = @max(0, (2 * k.roll_zeta * w + Lp) / Lda); // o avião já amortece o bastante: 0
        if (good(Kphia) and good(Kpa) and Kphia > 0 and Kphia <= 20 and Kpa >= 0 and Kpa <= 5) {
            ap.Kphia = Kphia;
            ap.Kpa = Kpa;
            r.roll = 1;
        }
    }

    // ---------------- guinada (rigidez do dutch roll pelo leme)
    const Nb = A.a(lm, 5, 1) * V;
    const Ndr = A.b(lm, 5, 2);
    if (good(Nb) and good(Ndr)) {
        if (@abs(Ndr) < 1e-3) {
            ap.Kbeta = 0; // sem leme (asa voadora): nada a fazer pelo leme
            r.yaw = 1;
        } else {
            const want = k.dr_w * k.dr_w;
            const Kb = if (Nb >= want) 0 else (Nb - want) / Ndr;
            r.yaw = @intFromBool(put(&ap.Kbeta, Kb, 0, 3));
        }
    }

    // ---------------- velocidade pelo motor
    const Xthr = A.b(lm, 0, 3);
    if (good(Xthr) and Xthr > 1e-2) {
        const KV = k.speed_w / Xthr;
        if (put(&ap.KV, KV, 0.02, 2)) {
            ap.KIV = KV * 0.4 * k.speed_w;
            ap.KHT = KV * 0.4;
            r.speed = 1;
        }
    }
    return r;
}

/// lineariza o avião em V (voo nivelado) e ajusta `p.ap`
pub fn tune(p: *T.Params, f: *const S.Flags, V: f64) Result {
    const lm = linear.linearize(p, f, V);
    return fromLinear(&lm, &p.ap, .{});
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

fn closedPitch(lm: *const linear.LinModel, ap: *const T.Autopilot) [2]f64 {
    const V = lm.V;
    const Za = lm.A[2 * 8 + 2];
    const Mq = lm.A[4 * 8 + 4] + lm.B[4 * 4 + 0] * ap.Kqe;
    const Ma = lm.A[4 * 8 + 2] * V + lm.B[4 * 4 + 0] * ap.Kae;
    const w = @sqrt(Za * Mq - Ma);
    return .{ w, -(Za + Mq) / (2 * w) };
}

test "autotune: dois aviões diferentes ficam com a mesma resposta em arfagem e rolagem" {
    var a = linear.LinModel{ .ok = 1, .V = 15 };
    a.A[2 * 8 + 2] = -3.6;
    a.A[4 * 8 + 2] = -42.9 / 15.0;
    a.A[4 * 8 + 4] = -5.6;
    a.B[4 * 4 + 0] = -39.8;
    a.A[3 * 8 + 3] = -23;
    a.B[3 * 4 + 1] = 134;
    a.A[5 * 8 + 1] = 10.7 / 15.0;
    a.B[5 * 4 + 2] = -9.1;
    a.B[0 * 4 + 3] = 3.3;
    var b = a;
    b.A[4 * 8 + 2] = -138.0 / 15.0; // bem mais estável e com comando mais forte
    b.B[4 * 4 + 0] = -118;
    b.B[3 * 4 + 1] = 343;
    b.B[5 * 4 + 2] = 0; // sem leme
    var pa = T.Autopilot{};
    var pb = T.Autopilot{};
    const ra = fromLinear(&a, &pa, .{});
    const rb = fromLinear(&b, &pb, .{});
    try testing.expect(ra.pitch == 1 and rb.pitch == 1 and ra.roll == 1 and rb.roll == 1);
    const ca = closedPitch(&a, &pa);
    try testing.expectApproxEqAbs(ra.w_sp, ca[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.65), ca[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.65), closedPitch(&b, &pb)[1], 1e-9);
    // os dois seguem o mesmo 80 % do α pedido só com o proporcional
    for ([_]struct { *const linear.LinModel, *const T.Autopilot }{ .{ &a, &pa }, .{ &b, &pb } }) |c| {
        const Ma = c[0].A[4 * 8 + 2] * c[0].V;
        const Mde = c[0].B[4 * 4 + 0];
        try testing.expectApproxEqAbs(@as(f64, 0.8), Mde * c[1].Kae / (Ma + Mde * c[1].Kae), 1e-9);
    }
    // rolagem: Lδa·Kphia = ω² nos dois
    try testing.expectApproxEqAbs(@as(f64, 144), 134 * pa.Kphia, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 144), 343 * pb.Kphia, 1e-9);
    try testing.expectEqual(@as(f64, 0), pb.Kbeta);
    try testing.expect(pa.Kbeta > 0);
}

test "autotune: modelo ruim ou números absurdos deixam os ganhos como estavam" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..5000) |_| {
        var lm = linear.LinModel{ .ok = @intFromBool(rnd.boolean()), .V = @floatCast(@as(f32, @bitCast(rnd.int(u32)))) };
        for (&lm.A) |*x| x.* = if (rnd.uintLessThan(u8, 4) == 0) @floatCast(@as(f32, @bitCast(rnd.int(u32)))) else rnd.float(f64) * 200 - 100;
        for (&lm.B) |*x| x.* = if (rnd.uintLessThan(u8, 4) == 0) @floatCast(@as(f32, @bitCast(rnd.int(u32)))) else rnd.float(f64) * 400 - 200;
        var ap = T.Autopilot{};
        _ = fromLinear(&lm, &ap, .{});
        inline for (@typeInfo(T.Autopilot).@"struct".fields) |f| try testing.expect(std.math.isFinite(@field(ap, f.name)));
        try testing.expect(ap.Kae > 0 and ap.Kae < 50 and ap.Kqe >= 0 and ap.Kphia >= 0 and ap.Kphia <= 20);
        try testing.expect(ap.Kbeta >= 0 and ap.Kbeta <= 3 and ap.KV > 0 and ap.KV <= 2);
    }
}
