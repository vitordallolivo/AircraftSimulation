//! Som do motor e do vento: acelerador → altura (pitch) e volume da hélice; velocidade do ar →
//! altura e volume do vento. Só as contas
//! (testáveis); quem toca é `audio/player.zig`. Mais motor = som mais agudo e mais alto, e a
//! mudança é suave (o motor não muda de rotação num quadro).
const std = @import("std");
const fz = @import("../util/fuzz.zig");

pub const Tuning = struct {
    pitch_idle: f64 = 0.55, // altura com motor parado/lento
    pitch_full: f64 = 1.6, // altura com motor cheio
    volume_idle: f64 = 0.12,
    volume_full: f64 = 1.0,
    response: f64 = 0.35, // s (constante do atraso)
};

pub const Engine = struct {
    level: f64 = 0, // 0..1 (rotação relativa, suavizada)

    /// `target` 0..1 (acelerador, ou rpm/rpm_máx); devolve altura e volume (já × master)
    pub fn step(e: *Engine, k: Tuning, target_in: f64, master_in: f64, dt_in: f64) Out {
        const target = clamp01(target_in);
        const dt = if (std.math.isFinite(dt_in)) std.math.clamp(dt_in, 0, 0.25) else 0;
        const tau = if (std.math.isFinite(k.response) and k.response > 1e-3) k.response else 1e-3;
        if (!std.math.isFinite(e.level)) e.level = 0;
        e.level += (target - e.level) * (1 - @exp(-dt / tau));
        e.level = clamp01(e.level);
        return map(k, e.level, master_in);
    }
};

pub const Out = struct { pitch: f32, volume: f32 };

pub fn map(k: Tuning, level_in: f64, master_in: f64) Out {
    const x = clamp01(level_in);
    const pitch = lerp(sane(k.pitch_idle, 0.1, 4, 0.55), sane(k.pitch_full, 0.1, 4, 1.6), x);
    const vol = lerp(sane(k.volume_idle, 0, 1, 0.12), sane(k.volume_full, 0, 1, 1), std.math.sqrt(x));
    return .{ .pitch = @floatCast(pitch), .volume = @floatCast(vol * clamp01(master_in)) };
}

/// vento passando: velocidade do ar (m/s) → altura e volume. Parado = silêncio; mais rápido =
/// mais alto e um pouco mais agudo (satura em `v_full`).
pub const WindTuning = struct {
    v_start: f64 = 3, // abaixo disto, nada
    v_full: f64 = 28, // daqui para cima, volume e altura máximos
    pitch_lo: f64 = 0.7,
    pitch_hi: f64 = 1.35,
    volume_max: f64 = 0.8,
};

pub fn wind(k: WindTuning, Va: f64, master_in: f64) Out {
    const span = @max(sane(k.v_full, 1, 200, 28) - sane(k.v_start, 0, 100, 3), 0.5);
    const v = if (std.math.isFinite(Va)) Va else 0;
    const x = clamp01((v - sane(k.v_start, 0, 100, 3)) / span);
    const pitch = lerp(sane(k.pitch_lo, 0.1, 4, 0.7), sane(k.pitch_hi, 0.1, 4, 1.35), x);
    const vol = sane(k.volume_max, 0, 1, 0.8) * x * x; // cresce devagar no começo
    return .{ .pitch = @floatCast(pitch), .volume = @floatCast(vol * clamp01(master_in)) };
}

fn lerp(a: f64, b: f64, x: f64) f64 {
    return a + (b - a) * x;
}
fn clamp01(v: f64) f64 {
    return if (std.math.isFinite(v)) std.math.clamp(v, 0, 1) else 0;
}
fn sane(v: f64, lo: f64, hi: f64, d: f64) f64 {
    return if (std.math.isFinite(v)) std.math.clamp(v, lo, hi) else d;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "mais motor = mais agudo e mais alto; muda suave" {
    const k: Tuning = .{};
    const lo = map(k, 0, 1);
    const hi = map(k, 1, 1);
    try testing.expect(hi.pitch > lo.pitch and hi.volume > lo.volume);
    var e: Engine = .{};
    const one = e.step(k, 1, 1, 1.0 / 60.0);
    try testing.expect(one.pitch < hi.pitch); // um quadro não chega lá
    for (0..240) |_| _ = e.step(k, 1, 1, 1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f64, 1), e.level, 1e-3);
    try testing.expectEqual(@as(f32, 0), map(k, 1, 0).volume); // mudo
}

test "vento: parado é silêncio, mais rápido é mais alto e mais agudo" {
    const k: WindTuning = .{};
    try testing.expectEqual(@as(f32, 0), wind(k, 2, 1).volume);
    const a = wind(k, 12, 1);
    const b = wind(k, 25, 1);
    try testing.expect(b.volume > a.volume and b.pitch > a.pitch);
}

fn fuzzEngine(_: void, src: *fz.Src) anyerror!void {
    var e: Engine = .{ .level = src.any() };
    const k: Tuning = .{ .pitch_idle = src.mostly(0.3, 1), .pitch_full = src.mostly(1, 2), .response = src.any() };
    while (!src.chance(10)) {
        const o = e.step(k, src.any(), src.any(), src.any());
        try testing.expect(std.math.isFinite(o.pitch) and o.pitch >= 0.1 and o.pitch <= 4);
        try testing.expect(std.math.isFinite(o.volume) and o.volume >= 0 and o.volume <= 1);
        const w = wind(.{ .v_start = src.any(), .v_full = src.any() }, src.any(), src.any());
        try testing.expect(std.math.isFinite(w.pitch) and w.volume >= 0 and w.volume <= 1);
    }
}

test "fuzz: som do motor" {
    try fz.check({}, fuzzEngine, .{});
}
