//! Canais de comando: entrada bruta do controle (eixos −1..1, gatilhos 0..1, botões) -> comandos
//! (δe, δa, δr em rad e acelerador 0..1), com a curva de cada canal (zona morta, expo, rate, trim,
//! inverter). Sem raylib: a leitura do controle fica em `main`/telas; aqui só as contas (testáveis).
//!
//! Padrão pedido: gatilho direito = motor, botões de ombro (LB/RB) = aileron (com rampa),
//! analógico esquerdo = profundor (y) e leme (x). O perfil (arquivo) vem na frente "Controle".
const std = @import("std");
const fz = @import("../util/fuzz.zig");

pub const Curve = struct {
    deadzone: f64 = 0.05, // 0..0,5
    expo: f64 = 0.3, // 0 = linear, 1 = só cúbica
    rate: f64 = 1.0, // 0..1 (fração do curso)
    trim: f64 = 0.0, // −0,25..0,25 (fração do curso)
    invert: bool = false,

    /// x em −1..1 -> −1..1 (saturado; entrada não finita = 0)
    pub fn apply(k: Curve, x_in: f64) f64 {
        if (!std.math.isFinite(x_in)) return 0;
        var x = std.math.clamp(x_in, -1, 1);
        if (k.invert) x = -x;
        const dz = std.math.clamp(k.deadzone, 0, 0.5);
        const ax = @abs(x);
        x = if (ax <= dz) 0 else std.math.sign(x) * (ax - dz) / (1 - dz);
        const e = std.math.clamp(k.expo, 0, 1);
        x = (1 - e) * x + e * x * x * x;
        x = x * std.math.clamp(k.rate, 0, 1) + std.math.clamp(k.trim, -0.25, 0.25);
        return std.math.clamp(x, -1, 1);
    }
};

pub const Raw = struct {
    stick_x: f64 = 0, // analógico esquerdo
    stick_y: f64 = 0, // + para baixo (puxar = cabrar)
    lb: bool = false,
    rb: bool = false,
    rt: f64 = 0, // gatilho direito 0..1
};

pub const Commands = struct { de: f64 = 0, da: f64 = 0, dr: f64 = 0, thr: f64 = 0 };

pub const Profile = struct {
    elevator: Curve = .{},
    aileron: Curve = .{ .expo = 0 },
    rudder: Curve = .{},
    throttle: Curve = .{ .deadzone = 0.02, .expo = 0 },
    de_max: f64 = std.math.degreesToRadians(20.0),
    da_max: f64 = std.math.degreesToRadians(20.0),
    dr_max: f64 = std.math.degreesToRadians(25.0),
    aileron_rate: f64 = 4.0, // botões: quanto o aileron anda por segundo (fração do curso)
};

/// estado entre quadros (rampa dos botões)
pub const State = struct {
    aileron: f64 = 0,

    pub fn step(s: *State, p: Profile, r: Raw, dt_in: f64) Commands {
        const dt = if (std.math.isFinite(dt_in)) std.math.clamp(dt_in, 0, 0.25) else 0;
        const target: f64 = if (r.lb == r.rb) 0 else if (r.rb) 1 else -1;
        const step_ = std.math.clamp(p.aileron_rate, 0, 100) * dt;
        s.aileron = if (!std.math.isFinite(s.aileron)) 0 else s.aileron + std.math.clamp(target - s.aileron, -step_, step_);
        // pull (stick_y > 0) = cabrar = bordo de fuga para cima = δe < 0 (convenção do núcleo)
        return .{
            .de = -p.elevator.apply(r.stick_y) * p.de_max,
            .da = p.aileron.apply(s.aileron) * p.da_max,
            .dr = p.rudder.apply(r.stick_x) * p.dr_max,
            .thr = std.math.clamp(p.throttle.apply(2 * r.rt - 1) * 0.5 + 0.5, 0, 1),
        };
    }
};

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "curva: zona morta, extremos e inverter" {
    const k: Curve = .{ .deadzone = 0.1, .expo = 0 };
    try testing.expectEqual(@as(f64, 0), k.apply(0.05));
    try testing.expectApproxEqAbs(@as(f64, 1), k.apply(1), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1), (Curve{ .invert = true }).apply(1), 1e-12);
}

test "LB/RB: aileron anda em rampa e volta ao centro" {
    var s: State = .{};
    const p: Profile = .{};
    var cmd = s.step(p, .{ .rb = true }, 0.1);
    try testing.expect(cmd.da > 0 and cmd.da < p.da_max);
    for (0..10) |_| cmd = s.step(p, .{ .rb = true }, 0.1);
    try testing.expectApproxEqAbs(p.da_max, cmd.da, 1e-9);
    for (0..10) |_| cmd = s.step(p, .{}, 0.1);
    try testing.expectApproxEqAbs(@as(f64, 0), cmd.da, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), s.step(p, .{ .rt = 1 }, 0).thr, 1e-9);
}

fn fuzzChannels(_: void, src: *fz.Src) anyerror!void {
    // entradas e perfis quaisquer: comandos sempre finitos e dentro dos limites
    const p: Profile = .{
        .elevator = .{ .deadzone = src.any(), .expo = src.any(), .rate = src.any(), .trim = src.any(), .invert = src.boolean() },
        .aileron = .{ .expo = src.mostly(0, 1) },
        .aileron_rate = src.any(),
    };
    var s: State = .{};
    while (!src.chance(10)) {
        const cmd = s.step(p, .{ .stick_x = src.any(), .stick_y = src.any(), .lb = src.boolean(), .rb = src.boolean(), .rt = src.any() }, src.any());
        inline for (.{ "de", "da", "dr", "thr" }) |f| try testing.expect(std.math.isFinite(@field(cmd, f)));
        try testing.expect(@abs(cmd.de) <= p.de_max + 1e-12 and @abs(cmd.da) <= p.da_max + 1e-12);
        try testing.expect(cmd.thr >= 0 and cmd.thr <= 1);
    }
}

test "fuzz: canais do controle" {
    try fz.check({}, fuzzChannels, .{});
}
