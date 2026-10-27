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
const types = @import("../types.zig");
const state = @import("../sim/state.zig");
const linear = @import("../sim/linear.zig");

/// a resposta pedida para cada malha (frequências em rad/s, amortecimentos)
pub const Targets = struct {
    dc_ratio: f64 = 0.8, // fração do α pedido seguida só pelo proporcional
    sp_min: f64 = 8, // rad/s: período curto mínimo em malha fechada
    sp_zeta: f64 = 0.65,
    roll_w: f64 = 12,
    roll_zeta: f64 = 0.9,
    dr_w: f64 = 4,
    speed_w: f64 = 0.8,
};

/// quais malhas foram ajustadas e a frequência do período curto antes e depois
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

/// verdadeiro se `value` é finito (nem NaN nem infinito)
fn good(value: f64) bool {
    return std.math.isFinite(value);
}

/// grava `value` em `target` se for finito e estiver em [low, high]; diz se gravou
fn put(target: *f64, value: f64, low: f64, high: f64) bool {
    if (!good(value) or value < low or value > high) return false;
    target.* = value;
    return true;
}

/// ganhos a partir do modelo linear (A, B por linhas; x = u v w p q r φ θ; u = δe δa δr thr)
pub fn fromLinear(model: *const linear.LinModel, gains: *types.Autopilot, targets: Targets) Result {
    var result = Result{};
    if (model.ok == 0 or !(model.V > 1)) return result;
    result.ok = 1;
    const nl = linear.nl;
    const nu = linear.nu;
    const Matrix = struct {
        fn stateEntry(lin_model: *const linear.LinModel, i: usize, j: usize) f64 {
            return lin_model.A[i * nl + j];
        }
        fn inputEntry(lin_model: *const linear.LinModel, i: usize, j: usize) f64 {
            return lin_model.B[i * nu + j];
        }
    };
    const airspeed = model.V;

    // ---------------- arfagem (período curto)
    const Za = Matrix.stateEntry(model, 2, 2);
    const Ma = Matrix.stateEntry(model, 4, 2) * airspeed;
    const Mq = Matrix.stateEntry(model, 4, 4);
    const Mde = Matrix.inputEntry(model, 4, 0);
    if (good(Za) and good(Ma) and good(Mq) and good(Mde) and @abs(Mde) > 1e-3) {
        const w0sq = Za * Mq - Ma;
        result.w_sp_open = if (w0sq > 0) @sqrt(w0sq) else 0;
        // Kae: o maior entre (a) seguir o α pedido com 80 % em regime (avião muito estável precisa
        // de ganho alto: Kae = 4 Mα/Mδe) e (b) período curto de pelo menos ω_min
        const Kae_dc = if (Ma / Mde > 0) targets.dc_ratio / (1 - targets.dc_ratio) * Ma / Mde else 0;
        const wmin = targets.sp_min;
        const Mq_min = -2 * targets.sp_zeta * wmin - Za;
        const Kae_w = ((Za * Mq_min - wmin * wmin) - Ma) / Mde;
        const Kae = @max(Kae_dc, Kae_w);
        // com Mα' fixo, ω e M'q saem de: ω² + 2ζZα ω + Zα² + M'α = 0 e M'q = −2ζω − Zα
        const Ma2 = Ma + Mde * Kae;
        const disc = targets.sp_zeta * targets.sp_zeta * Za * Za - Za * Za - Ma2;
        if (good(Kae) and Kae > 0 and Kae < 50 and disc > 0) {
            const omega = -targets.sp_zeta * Za + @sqrt(disc);
            const Mq2 = -2 * targets.sp_zeta * omega - Za;
            const Kqe = @max(0, (Mq2 - Mq) / Mde); // o avião já amortece o bastante: 0
            if (good(omega) and good(Kqe) and Kqe < 10) {
                gains.Kae = Kae;
                gains.Kqe = Kqe;
                gains.KIa = Kae; // integral do erro de α (tira o resto do erro em regime)
                gains.Kthe = Kae * 0.375; // no chão depois do pouso (segura θ): mesma proporção do padrão
                result.w_sp = omega;
                result.pitch = 1;
            }
        }
    }

    // ---------------- rolagem
    const Lp = Matrix.stateEntry(model, 3, 3);
    const Lda = Matrix.inputEntry(model, 3, 1);
    if (good(Lp) and good(Lda) and @abs(Lda) > 1e-3) {
        const omega = targets.roll_w;
        const Kphia = omega * omega / Lda;
        const Kpa = @max(0, (2 * targets.roll_zeta * omega + Lp) / Lda); // o avião já amortece o bastante: 0
        if (good(Kphia) and good(Kpa) and Kphia > 0 and Kphia <= 20 and Kpa >= 0 and Kpa <= 5) {
            gains.Kphia = Kphia;
            gains.Kpa = Kpa;
            result.roll = 1;
        }
    }

    // ---------------- guinada (rigidez do dutch roll pelo leme)
    const Nb = Matrix.stateEntry(model, 5, 1) * airspeed;
    const Ndr = Matrix.inputEntry(model, 5, 2);
    if (good(Nb) and good(Ndr)) {
        if (@abs(Ndr) < 1e-3) {
            gains.Kbeta = 0; // sem leme (asa voadora): nada a fazer pelo leme
            result.yaw = 1;
        } else {
            const want = targets.dr_w * targets.dr_w;
            const Kb = if (Nb >= want) 0 else (Nb - want) / Ndr;
            result.yaw = @intFromBool(put(&gains.Kbeta, Kb, 0, 3));
        }
    }

    // ---------------- velocidade pelo motor
    const Xthr = Matrix.inputEntry(model, 0, 3);
    if (good(Xthr) and Xthr > 1e-2) {
        const KV = targets.speed_w / Xthr;
        if (put(&gains.KV, KV, 0.02, 2)) {
            gains.KIV = KV * 0.4 * targets.speed_w;
            gains.KHT = KV * 0.4;
            result.speed = 1;
        }
    }
    return result;
}

/// lineariza o avião na velocidade `airspeed` (voo nivelado) e ajusta `params.ap`
pub fn tune(params: *types.Params, flags: *const state.Flags, airspeed: f64) Result {
    const model = linear.linearize(params, flags, airspeed);
    return fromLinear(&model, &params.ap, .{});
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

/// frequência e amortecimento do período curto em malha fechada
fn closedPitch(model: *const linear.LinModel, gains: *const types.Autopilot) [2]f64 {
    const airspeed = model.V;
    const Za = model.A[2 * 8 + 2];
    const Mq = model.A[4 * 8 + 4] + model.B[4 * 4 + 0] * gains.Kqe;
    const Ma = model.A[4 * 8 + 2] * airspeed + model.B[4 * 4 + 0] * gains.Kae;
    const omega = @sqrt(Za * Mq - Ma);
    return .{ omega, -(Za + Mq) / (2 * omega) };
}

test "autotune: dois aviões diferentes ficam com a mesma resposta em arfagem e rolagem" {
    var model_a = linear.LinModel{ .ok = 1, .V = 15 };
    model_a.A[2 * 8 + 2] = -3.6;
    model_a.A[4 * 8 + 2] = -42.9 / 15.0;
    model_a.A[4 * 8 + 4] = -5.6;
    model_a.B[4 * 4 + 0] = -39.8;
    model_a.A[3 * 8 + 3] = -23;
    model_a.B[3 * 4 + 1] = 134;
    model_a.A[5 * 8 + 1] = 10.7 / 15.0;
    model_a.B[5 * 4 + 2] = -9.1;
    model_a.B[0 * 4 + 3] = 3.3;
    var model_b = model_a;
    model_b.A[4 * 8 + 2] = -138.0 / 15.0; // bem mais estável e com comando mais forte
    model_b.B[4 * 4 + 0] = -118;
    model_b.B[3 * 4 + 1] = 343;
    model_b.B[5 * 4 + 2] = 0; // sem leme
    var pa = types.Autopilot{};
    var pb = types.Autopilot{};
    const ra = fromLinear(&model_a, &pa, .{});
    const rb = fromLinear(&model_b, &pb, .{});
    try testing.expect(ra.pitch == 1 and rb.pitch == 1 and ra.roll == 1 and rb.roll == 1);
    const ca = closedPitch(&model_a, &pa);
    try testing.expectApproxEqAbs(ra.w_sp, ca[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.65), ca[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.65), closedPitch(&model_b, &pb)[1], 1e-9);
    // os dois seguem o mesmo 80 % do α pedido só com o proporcional
    for ([_]struct { *const linear.LinModel, *const types.Autopilot }{ .{ &model_a, &pa }, .{ &model_b, &pb } }) |pair| {
        const Ma = pair[0].A[4 * 8 + 2] * pair[0].V;
        const Mde = pair[0].B[4 * 4 + 0];
        try testing.expectApproxEqAbs(@as(f64, 0.8), Mde * pair[1].Kae / (Ma + Mde * pair[1].Kae), 1e-9);
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
        var model = linear.LinModel{ .ok = @intFromBool(rnd.boolean()), .V = @floatCast(@as(f32, @bitCast(rnd.int(u32)))) };
        for (&model.A) |*entry| entry.* = if (rnd.uintLessThan(u8, 4) == 0) @floatCast(@as(f32, @bitCast(rnd.int(u32)))) else rnd.float(f64) * 200 - 100;
        for (&model.B) |*entry| entry.* = if (rnd.uintLessThan(u8, 4) == 0) @floatCast(@as(f32, @bitCast(rnd.int(u32)))) else rnd.float(f64) * 400 - 200;
        var gains = types.Autopilot{};
        _ = fromLinear(&model, &gains, .{});
        inline for (@typeInfo(types.Autopilot).@"struct".fields) |field| try testing.expect(std.math.isFinite(@field(gains, field.name)));
        try testing.expect(gains.Kae > 0 and gains.Kae < 50 and gains.Kqe >= 0 and gains.Kphia >= 0 and gains.Kphia <= 20);
        try testing.expect(gains.Kbeta >= 0 and gains.Kbeta <= 3 and gains.KV > 0 and gains.KV <= 2);
    }
}
