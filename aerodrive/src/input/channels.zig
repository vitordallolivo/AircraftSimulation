//! Canais de comando: o que está apertado no controle (eixos −1..1, gatilhos 0..1, botões) ->
//! comandos (δe, δa, δr em rad e acelerador 0..1), com a curva de cada canal (zona morta, expo,
//! curso, trim, inverter). Sem raylib: a leitura fica em `gamepad.zig`; aqui só as contas.
//!
//! Cada canal lê de uma `Source` (eixo, gatilho ou o par LB/RB em rampa) — tudo remapeável no menu
//! Controle. Esquemas prontos (`Scheme.sources`):
//!   xbox     analógico esquerdo: aileron (x) e profundor (y) · LB/RB: leme (em rampa) · RT: motor
//!   radio2   rádio modo 2: esquerdo = motor (y) e leme (x) · direito = profundor (y) e aileron (x)
//!   radio1   rádio modo 1: esquerdo = profundor (y) e leme (x) · direito = motor (y) e aileron (x)
//! O teclado vale em qualquer esquema (setas, A/D, W/S).
const std = @import("std");
const fz = @import("../util/fuzz.zig");

/// de onde um canal lê
pub const Source = enum {
    lx,
    ly,
    rx,
    ry,
    lt,
    rt,
    buttons, // LB/RB em rampa
    none,

    pub const all = [_]Source{ .lx, .ly, .rx, .ry, .lt, .rt, .buttons, .none };

    pub fn label(s: Source) [:0]const u8 {
        return switch (s) {
            .lx => "analógico esq. ← →",
            .ly => "analógico esq. ↑↓",
            .rx => "analógico dir. ← →",
            .ry => "analógico dir. ↑↓",
            .lt => "gatilho LT",
            .rt => "gatilho RT",
            .buttons => "LB / RB",
            .none => "nenhum",
        };
    }

    fn stick(s: Source) bool {
        return s == .lx or s == .ly or s == .rx or s == .ry;
    }
};

/// botões do controle (nomes do Xbox)
pub const Pad = enum {
    a,
    b,
    x,
    y,
    lb,
    rb,
    lt,
    rt,
    back,
    start,
    ls,
    rs,
    up,
    down,
    left,
    right,
};

/// ações do voo que vão num botão
pub const Action = enum {
    pause,
    mode,
    drop,
    record,
    camera,
    restart,

    pub const all = [_]Action{ .pause, .mode, .drop, .record, .camera, .restart };

    pub fn label(a: Action) [:0]const u8 {
        return switch (a) {
            .pause => "Pausa",
            .mode => "Manual ⇄ automático",
            .drop => "Soltar o LAPES",
            .record => "Gravar / parar",
            .camera => "Trocar a câmera",
            .restart => "Recomeçar",
        };
    }

    /// a tecla equivalente (fixa)
    pub fn key(a: Action) [:0]const u8 {
        return switch (a) {
            .pause => "Esc",
            .mode => "M",
            .drop => "L",
            .record => "G",
            .camera => "C",
            .restart => "R",
        };
    }
};

pub const Bindings = struct {
    pause: Pad = .start,
    mode: Pad = .y,
    drop: Pad = .x,
    record: Pad = .back,
    camera: Pad = .b,
    restart: Pad = .up,

    pub fn get(b: Bindings, a: Action) Pad {
        return switch (a) {
            inline else => |t| @field(b, @tagName(t)),
        };
    }

    /// põe `p` na ação; se outra ação usava `p`, ela fica com o botão antigo (troca, sem conflito)
    pub fn set(b: *Bindings, a: Action, p: Pad) void {
        const old = b.get(a);
        inline for (Action.all) |o| {
            if (o != a and @field(b, @tagName(o)) == p) @field(b, @tagName(o)) = old;
        }
        switch (a) {
            inline else => |t| @field(b, @tagName(t)) = p,
        }
    }
};

pub const Scheme = enum {
    xbox,
    radio2,
    radio1,
    custom,

    pub fn label(s: Scheme) [:0]const u8 {
        return switch (s) {
            .xbox => "Controle (Xbox)",
            .radio2 => "Rádio modo 2",
            .radio1 => "Rádio modo 1",
            .custom => "Personalizado",
        };
    }

    /// profundor, aileron, leme, motor
    pub fn sources(s: Scheme) ?[4]Source {
        return switch (s) {
            .xbox => .{ .ly, .lx, .buttons, .rt },
            .radio2 => .{ .ry, .rx, .lx, .ly },
            .radio1 => .{ .ly, .rx, .lx, .ry },
            .custom => null,
        };
    }
};

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

/// o que está apertado (físico): eixos do controle + teclado
pub const Raw = struct {
    lx: f64 = 0, // analógico esquerdo (+ direita)
    ly: f64 = 0, // + para baixo (puxar)
    rx: f64 = 0,
    ry: f64 = 0,
    lt: f64 = 0, // gatilhos 0..1
    rt: f64 = 0,
    lb: bool = false,
    rb: bool = false,
    // teclado (vale em qualquer esquema): −1, 0, 1; motor: 0..1 ou null (sem tecla)
    key_elev: f64 = 0, // + = puxar
    key_ail: f64 = 0,
    key_rud: f64 = 0,
    key_thr: ?f64 = null,
};

pub const Commands = struct { de: f64 = 0, da: f64 = 0, dr: f64 = 0, thr: f64 = 0 };

pub const Profile = struct {
    scheme: Scheme = .xbox,
    // de onde cada canal lê (o esquema escolhido preenche; mudar um vira "Personalizado")
    src_elev: Source = .ly,
    src_ail: Source = .lx,
    src_rud: Source = .buttons,
    src_thr: Source = .rt,

    elevator: Curve = .{},
    aileron: Curve = .{ .expo = 0.2 },
    rudder: Curve = .{ .expo = 0 },
    throttle: Curve = .{ .deadzone = 0.02, .expo = 0 },
    // deflexão máxima pedida; o jogo nunca passa do estol da superfície (padrão: até o estol)
    de_max: f64 = std.math.degreesToRadians(30.0),
    da_max: f64 = std.math.degreesToRadians(30.0),
    dr_max: f64 = std.math.degreesToRadians(30.0),
    button_rate: f64 = 4.0, // LB/RB: quanto o leme anda por segundo (fração do curso)
    buttons: Bindings = .{},

    pub fn applyScheme(p: *Profile, s: Scheme) void {
        p.scheme = s;
        if (s.sources()) |src| {
            p.src_elev = src[0];
            p.src_ail = src[1];
            p.src_rud = src[2];
            p.src_thr = src[3];
        }
    }
};

/// a entrada de cada canal antes da curva (−1..1; motor também −1..1 = 0..100 %)
pub const Inputs = struct { elev: f64 = 0, ail: f64 = 0, rud: f64 = 0, thr: f64 = -1 };

/// estado entre quadros (rampa dos botões)
pub const State = struct {
    buttons: f64 = 0, // posição do leme pelos botões (−1..1)

    /// entradas de cada canal pelo esquema (sem curva) — o menu Controle mostra o ponto com isto
    pub fn inputs(s: *State, p: Profile, r: Raw, dt_in: f64) Inputs {
        const dt = if (std.math.isFinite(dt_in)) std.math.clamp(dt_in, 0, 0.25) else 0;
        const ok = struct {
            fn f(v: f64) f64 {
                return if (std.math.isFinite(v)) std.math.clamp(v, -1, 1) else 0;
            }
        }.f;
        const target: f64 = if (r.lb == r.rb) 0 else if (r.rb) 1 else -1;
        const step_ = std.math.clamp(if (std.math.isFinite(p.button_rate)) p.button_rate else 4, 0, 100) * dt;
        s.buttons = if (!std.math.isFinite(s.buttons)) 0 else s.buttons + std.math.clamp(target - s.buttons, -step_, step_);
        const read = struct {
            fn f(st: *const State, raw: Raw, src: Source) f64 {
                const v = switch (src) {
                    .lx => raw.lx,
                    .ly => raw.ly,
                    .rx => raw.rx,
                    .ry => raw.ry,
                    .lt => 2 * std.math.clamp(if (std.math.isFinite(raw.lt)) raw.lt else 0, 0, 1) - 1,
                    .rt => 2 * std.math.clamp(if (std.math.isFinite(raw.rt)) raw.rt else 0, 0, 1) - 1,
                    .buttons => st.buttons,
                    .none => 0,
                };
                return if (std.math.isFinite(v)) std.math.clamp(v, -1, 1) else 0;
            }
        }.f;
        // motor num analógico: para cima (y negativo) = mais motor; sem fonte = parado
        const thr: f64 = if (p.src_thr == .none) -1 else if (p.src_thr.stick()) -read(s, r, p.src_thr) else read(s, r, p.src_thr);
        var in: Inputs = .{ .elev = read(s, r, p.src_elev), .ail = read(s, r, p.src_ail), .rud = read(s, r, p.src_rud), .thr = thr };
        if (r.key_elev != 0) in.elev = ok(r.key_elev);
        if (r.key_ail != 0) in.ail = ok(r.key_ail);
        if (r.key_rud != 0) in.rud = ok(r.key_rud);
        if (r.key_thr) |t| if (std.math.isFinite(t)) {
            in.thr = @max(in.thr, 2 * std.math.clamp(t, 0, 1) - 1);
        };
        return in;
    }

    pub fn step(s: *State, p: Profile, r: Raw, dt: f64) Commands {
        const in = s.inputs(p, r, dt);
        // puxar (+) = cabrar = bordo de fuga para cima = δe < 0 (convenção do núcleo)
        return .{
            .de = -p.elevator.apply(in.elev) * p.de_max,
            .da = p.aileron.apply(in.ail) * p.da_max,
            .dr = p.rudder.apply(in.rud) * p.dr_max,
            .thr = std.math.clamp(p.throttle.apply(in.thr) * 0.5 + 0.5, 0, 1),
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

test "xbox: aileron no analógico, leme em rampa no LB/RB, motor no RT" {
    var s: State = .{};
    const p: Profile = .{ .aileron = .{ .expo = 0, .deadzone = 0 } };
    var cmd = s.step(p, .{ .lx = 1 }, 0.1);
    try testing.expectApproxEqAbs(p.da_max, cmd.da, 1e-9);
    cmd = s.step(p, .{ .rb = true }, 0.1);
    try testing.expect(cmd.dr > 0 and cmd.dr < p.dr_max);
    for (0..10) |_| cmd = s.step(p, .{ .rb = true }, 0.1);
    try testing.expectApproxEqAbs(p.dr_max, cmd.dr, 1e-9);
    for (0..10) |_| cmd = s.step(p, .{}, 0.1);
    try testing.expectApproxEqAbs(@as(f64, 0), cmd.dr, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), s.step(p, .{ .rt = 1 }, 0).thr, 1e-9);
    try testing.expect(s.step(p, .{ .ly = 1 }, 0).de < 0); // puxar = cabrar
}

test "rádio modo 2: motor no esquerdo (y para cima), aileron no direito" {
    var s: State = .{};
    var p: Profile = .{ .aileron = .{ .expo = 0, .deadzone = 0 } };
    p.applyScheme(.radio2);
    try testing.expectApproxEqAbs(@as(f64, 1), s.step(p, .{ .ly = -1 }, 0).thr, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), s.step(p, .{ .ly = 1 }, 0).thr, 1e-9);
    try testing.expectApproxEqAbs(p.da_max, s.step(p, .{ .rx = 1 }, 0).da, 1e-9);
    try testing.expect(s.step(p, .{ .lx = 1 }, 0).dr > 0);
    try testing.expectApproxEqAbs(@as(f64, 0), s.step(p, .{ .lx = 1 }, 0).da, 1e-12);
}

test "remapear: motor no LT e aileron no LB/RB" {
    var s: State = .{};
    const p: Profile = .{ .scheme = .custom, .src_thr = .lt, .src_ail = .buttons, .aileron = .{ .expo = 0 } };
    try testing.expectApproxEqAbs(@as(f64, 1), s.step(p, .{ .lt = 1 }, 0).thr, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), s.step(p, .{ .rt = 1 }, 0).thr, 1e-9);
    for (0..20) |_| _ = s.step(p, .{ .rb = true }, 0.1);
    try testing.expectApproxEqAbs(p.da_max, s.step(p, .{ .rb = true }, 0.1).da, 1e-9);
}

test "remapear botões: trocar sem deixar dois iguais" {
    var b: Bindings = .{};
    b.set(.drop, .start); // a pausa usava START: fica com o X
    try testing.expectEqual(Pad.start, b.drop);
    try testing.expectEqual(Pad.x, b.pause);
    var prng = std.Random.DefaultPrng.init(5);
    for (0..2000) |_| {
        const r = prng.random();
        b.set(Action.all[r.uintLessThan(usize, Action.all.len)], @enumFromInt(r.uintLessThan(u8, 16)));
        for (Action.all, 0..) |x, i| for (Action.all[i + 1 ..]) |y| try testing.expect(b.get(x) != b.get(y));
    }
}

test "teclado vale em qualquer esquema" {
    var s: State = .{};
    for ([_]Scheme{ .xbox, .radio2, .radio1 }) |sc| {
        var p: Profile = .{};
        p.applyScheme(sc);
        try testing.expect(s.step(p, .{ .key_ail = 1 }, 0).da > 0);
        try testing.expectApproxEqAbs(@as(f64, 1), s.step(p, .{ .key_thr = 1 }, 0).thr, 1e-9);
    }
}

fn fuzzChannels(_: void, src: *fz.Src) anyerror!void {
    // entradas e perfis quaisquer: comandos sempre finitos e dentro dos limites
    const p: Profile = .{
        .src_elev = Source.all[src.index(Source.all.len)],
        .src_ail = Source.all[src.index(Source.all.len)],
        .src_rud = Source.all[src.index(Source.all.len)],
        .src_thr = Source.all[src.index(Source.all.len)],
        .elevator = .{ .deadzone = src.any(), .expo = src.any(), .rate = src.any(), .trim = src.any(), .invert = src.boolean() },
        .aileron = .{ .expo = src.mostly(0, 1) },
        .button_rate = src.any(),
    };
    var s: State = .{};
    while (!src.chance(10)) {
        const cmd = s.step(p, .{ .lx = src.any(), .ly = src.any(), .rx = src.any(), .ry = src.any(), .lb = src.boolean(), .rb = src.boolean(), .rt = src.any(), .lt = src.any(), .key_elev = if (src.chance(4)) src.any() else 0, .key_thr = if (src.chance(4)) src.any() else null }, src.any());
        inline for (.{ "de", "da", "dr", "thr" }) |f| try testing.expect(std.math.isFinite(@field(cmd, f)));
        try testing.expect(@abs(cmd.de) <= p.de_max + 1e-12 and @abs(cmd.da) <= p.da_max + 1e-12 and @abs(cmd.dr) <= p.dr_max + 1e-12);
        try testing.expect(cmd.thr >= 0 and cmd.thr <= 1);
    }
}

test "fuzz: canais do controle" {
    try fz.check({}, fuzzChannels, .{});
}
