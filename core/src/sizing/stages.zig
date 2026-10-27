//! Estágios da cadeia de dimensionamento, cada um uma função pura com entradas e saídas pequenas:
//!
//!   geometry  envergadura, área            → S, b, alongamento
//!   polar     geometria, perfil, tipo      → C_D0, K, C_L,max, C_L na corrida
//!   envelope  polar, curva de tração, W    → V_S, V_max, subida, L/D
//!   takeoff   polar, curva, massa          → corrida (ou pairado)
//!   mass      geometria, conjuntos, tipo   → PV
//!
//! A tração entra como uma curva T(V) já calculada (`Curve`): quem a calcula é um `Thrust`
//! (o do núcleo, `CoreThrust`, ou um mock nos testes) — ver chain.zig.
const std = @import("std");
const sizing_types = @import("types.zig");
const kinds = @import("kinds.zig");

pub const g0 = 9.80665;
pub const V_top = 50.0; // a curva vai de 0 a V_top (m/s)

pub const Curve = struct {
    V: [sizing_types.n_curve]f64,
    T: [sizing_types.n_curve]f64, // tração total (N), ≥ 0

    pub fn grid() [sizing_types.n_curve]f64 {
        var v: [sizing_types.n_curve]f64 = undefined;
        for (&v, 0..) |*x, i| x.* = V_top * @as(f64, @floatFromInt(i)) / @as(f64, sizing_types.n_curve - 1);
        return v;
    }
    pub fn at(c: *const Curve, V: f64) f64 {
        if (V <= c.V[0]) return c.T[0];
        for (0..sizing_types.n_curve - 1) |i| {
            if (V <= c.V[i + 1]) {
                const f = (V - c.V[i]) / (c.V[i + 1] - c.V[i]);
                return c.T[i] + f * (c.T[i + 1] - c.T[i]);
            }
        }
        return c.T[sizing_types.n_curve - 1];
    }
};

// ------------------------------------------------------------------ geometria
pub const Geo = struct { S: f64, b: f64, AR: f64, AR_eq: f64, c: f64 };

/// `area` é a área total das asas (o biplano a divide em duas de mesma envergadura)
pub fn geometry(comptime K: type, span: f64, area: f64) Geo {
    const b = @max(span, 1e-3);
    const Sw = @max(area, 1e-4);
    const AR_eq = b * b / Sw; // monoplano equivalente (mesma envergadura e área total)
    return .{ .S = Sw, .b = b, .AR = AR_eq * @as(f64, K.wings), .AR_eq = AR_eq, .c = Sw / (b * @as(f64, K.wings)) };
}

// ------------------------------------------------------------------ perfil da asa (raiz → ponta)
/// propriedades 2D médias da asa trapezoidal com perfil da raiz e da ponta: interpolação linear ao longo
/// da envergadura pesada pela corda, ∫p c dη / ∫c dη = p_r + (p_t − p_r)(1 + 2λ)/(3(1 + λ))
pub fn blendAirfoils(root: sizing_types.AirfoilData, tip: sizing_types.AirfoilData, taper: f64) sizing_types.AirfoilData {
    const l = std.math.clamp(taper, 0.05, 1.0);
    const f = (1.0 + 2.0 * l) / (3.0 * (1.0 + l));
    const mix = struct {
        fn m(a: f64, b: f64, w: f64) f64 {
            return a + (b - a) * w;
        }
    }.m;
    return .{ .cla = mix(root.cla, tip.cla, f), .a0_deg = mix(root.a0_deg, tip.a0_deg, f), .clmax = mix(root.clmax, tip.clmax, f), .cd0 = mix(root.cd0, tip.cd0, f), .cm = mix(root.cm, tip.cm, f) };
}

// ------------------------------------------------------------------ polar
pub const Polar = struct { CD0: f64, K: f64, CLmax: f64, CLg: f64 };

/// `extra_CDS`: C_D·S que o arranjo acrescenta (naceles)
pub fn polar(comptime K: type, cfg: *const sizing_types.SizingCfg, geo: Geo, af: sizing_types.AirfoilData, extra_CDS: f64) Polar {
    const tail = if (K.tail) cfg.tail_area_frac * cfg.tail_drag_frac else 0.0;
    const CLmax = @max(K.clmaxFactor(cfg) * af.clmax, 0.1);
    return .{
        .CD0 = @max(af.cd0, 0.0) * (1.0 + tail) + (@max(cfg.fuselage_CDS, 0.0) + @max(extra_CDS, 0.0)) / geo.S,
        .K = K.inducedFactor(cfg) / (std.math.pi * geo.AR_eq * std.math.clamp(cfg.oswald, 0.3, 1.0)),
        .CLmax = CLmax,
        .CLg = std.math.clamp(cfg.cl_ground, 0.0, 1.0) * CLmax,
    };
}

// ------------------------------------------------------------------ envelope
pub const Env = struct {
    Vs: f64,
    Vmax: f64, // NaN: a tração não vence o arrasto em nenhuma V
    RC: f64, // subida máxima (m/s)
    TW: f64,
    V_LD: f64,
    LD: f64,
    grad: f64, // gradiente de subida máximo, sen γ (adimensional)
    D: [sizing_types.n_curve]f64, // arrasto de voo nivelado (tração requerida, N) na grade inteira; V = 0: infinito
};

pub fn stallSpeed(p: Polar, W: f64, Sw: f64, rho: f64) f64 {
    return @sqrt(2.0 * W / (rho * Sw * p.CLmax));
}

pub fn envelope(p: Polar, c: *const Curve, W: f64, Sw: f64, rho: f64) Env {
    var e: Env = .{ .Vs = stallSpeed(p, W, Sw, rho), .Vmax = std.math.nan(f64), .RC = -std.math.inf(f64), .TW = c.T[0] / W, .V_LD = @sqrt(2.0 * W / (rho * Sw) * @sqrt(p.K / @max(p.CD0, 1e-6))), .LD = 0.5 / @sqrt(p.K * @max(p.CD0, 1e-6)), .grad = -std.math.inf(f64), .D = undefined };
    var prev_ok = false;
    var prev_V: f64 = 0;
    var prev_m: f64 = 0;
    for (0..sizing_types.n_curve) |i| {
        const V = c.V[i];
        const q = 0.5 * rho * V * V;
        const CL = if (q > 0) W / (q * Sw) else std.math.inf(f64);
        const D = if (q > 0) q * Sw * (p.CD0 + p.K * CL * CL) else std.math.inf(f64);
        e.D[i] = D; // a curva inteira (o C_L de voo nivelado, sem limite); V_S marca onde o voo existe
        if (V < e.Vs) continue;
        const m = c.T[i] - D;
        e.RC = @max(e.RC, m * V / W);
        e.grad = @max(e.grad, m / W);
        const ok = m >= 0;
        if (ok) {
            e.Vmax = V;
        } else if (prev_ok) { // cruzou entre o ponto anterior e este: interpola
            e.Vmax = prev_V + (V - prev_V) * prev_m / (prev_m - m);
        }
        prev_ok = ok;
        prev_V = V;
        prev_m = m;
    }
    if (!std.math.isFinite(e.RC)) e.RC = std.math.nan(f64);
    if (!std.math.isFinite(e.grad)) e.grad = std.math.nan(f64);
    return e;
}

// ------------------------------------------------------------------ curva, teto, pouso
/// fator de carga sustentado na velocidade V: o que a tração mantém, n = √(q/(K W/S) (T/W − q C_D0/(W/S))),
/// limitado pelo estol, n = q C_L,max/(W/S) (Gudmundsson, cap. 3; como no diagrama de restrições)
pub fn sustainedN(p: Polar, c: *const Curve, W: f64, Sw: f64, rho: f64, V: f64) f64 {
    const q = 0.5 * rho * V * V;
    const ws = W / Sw;
    const tw = c.at(V) / W;
    const n_thr = @sqrt(@max(q / (p.K * ws) * (tw - q * p.CD0 / ws), 0.0));
    return @min(n_thr, q * p.CLmax / ws);
}

/// densidade ISA pela altitude-densidade (a mesma de `isa_density` do aerosim)
pub fn isaRho(h: f64) f64 {
    return 1.225 * std.math.pow(f64, @max(1.0 - 2.25577e-5 * h, 1e-6), 4.2559);
}

/// altitude-densidade de uma densidade (inversa de `isaRho`)
pub fn isaAltitude(rho: f64) f64 {
    return (1.0 - std.math.pow(f64, @max(rho, 1e-6) / 1.225, 1.0 / 4.2559)) / 2.25577e-5;
}

/// teto: a altitude-densidade em que a subida máxima cai a `roc` (tração ∝ ρ); NaN se não sobe nem no campo
pub fn ceiling(p: Polar, c: *const Curve, W: f64, Sw: f64, rho: f64, roc: f64) f64 {
    const h0 = isaAltitude(rho);
    const rcAt = struct {
        fn f(pp: Polar, cc: *const Curve, w: f64, s: f64, r0: f64, h: f64) f64 {
            const rh = isaRho(h);
            var ch = cc.*;
            for (&ch.T) |*t| t.* *= rh / r0;
            const e = envelope(pp, &ch, w, s, rh);
            return if (std.math.isFinite(e.RC)) e.RC else -1e9;
        }
    }.f;
    if (rcAt(p, c, W, Sw, rho, h0) < roc) return std.math.nan(f64);
    var lo = h0;
    var hi = h0 + 9000.0;
    if (rcAt(p, c, W, Sw, rho, hi) >= roc) return hi;
    for (0..30) |_| {
        const mid = 0.5 * (lo + hi);
        if (rcAt(p, c, W, Sw, rho, mid) >= roc) lo = mid else hi = mid;
    }
    return lo;
}

/// corrida de pouso: toque a 1,15 V_S, frenagem μ_f, sem arrasto nem sustentação (conservador; a mesma
/// conta do limite de pouso do diagrama de restrições)
pub fn landingRun(p: Polar, W: f64, Sw: f64, rho: f64, mu_brake: f64) f64 {
    return 1.15 * 1.15 * (W / Sw) / (rho * p.CLmax * g0 * @max(mu_brake, 1e-3));
}

// ------------------------------------------------------------------ decolagem
/// corrida até 1,1 V_S (m); inf se não acelera. tilt: inclinação do motor (rad)
pub fn takeoffRun(p: Polar, c: *const Curve, m: f64, Sw: f64, rho: f64, mu: f64, tilt: f64) f64 {
    const W = m * g0;
    const v_lof = 1.1 * stallSpeed(p, W, Sw, rho);
    const ct = @cos(tilt);
    const st = @sin(tilt);
    var v: f64 = 0;
    var x: f64 = 0;
    const dt = 0.01;
    var k: usize = 0;
    while (k < 12000) : (k += 1) {
        const q = 0.5 * rho * v * v;
        const Tv = c.at(v);
        const L = q * Sw * p.CLg + Tv * st;
        const D = q * Sw * (p.CD0 + p.K * p.CLg * p.CLg);
        const a = (Tv * ct - D - mu * @max(W - L, 0.0)) / m;
        if (a <= 0) return std.math.inf(f64);
        // passo semi-implícito na posição: exato para aceleração constante
        x += v * dt + 0.5 * a * dt * dt;
        v += a * dt;
        if (v >= v_lof) return x - (v * v - v_lof * v_lof) / (2.0 * a); // volta ao instante exato
    }
    return std.math.inf(f64);
}

/// decola na vertical: tração estática ≥ margem × peso
pub fn canHover(c: *const Curve, m: f64, margin: f64) bool {
    return c.T[0] >= margin * m * g0;
}

// ------------------------------------------------------------------ massa
pub const Mass = struct { pv: f64, wing: f64, tail: f64, propulsion: f64, fixed: f64 };

pub fn emptyMass(comptime K: type, cfg: *const sizing_types.SizingCfg, geo: Geo, set_mass: f64, n_motor: f64) Mass {
    const wing = cfg.wing_density * geo.S;
    const tail = if (K.tail) cfg.tail_density * cfg.tail_area_frac * geo.S else 0.0;
    const prop = n_motor * set_mass;
    const gear = if (K.hover == kinds.Hover.required) 0.0 else cfg.gear_mass;
    const fixed = cfg.fuselage_mass + cfg.systems_mass + gear + K.extraMass(cfg, prop);
    return .{ .pv = wing + tail + prop + fixed, .wing = wing, .tail = tail, .propulsion = prop, .fixed = fixed };
}

// ------------------------------------------------------------------ testes (mocks no lugar da tração)
const testing = std.testing;
const fuzz = @import("../util/fuzz.zig");

/// mock de tração: T = T0 (1 − V/Vz), ≥ 0
pub fn linearCurve(T0: f64, Vz: f64) Curve {
    var c: Curve = .{ .V = Curve.grid(), .T = undefined };
    for (c.V, 0..) |V, i| c.T[i] = @max(T0 * (1.0 - V / Vz), 0.0);
    return c;
}

test "dois perfis: retangular pesa meio a meio; perfil igual não muda nada" {
    const a: sizing_types.AirfoilData = .{ .clmax = 2.0, .cd0 = 0.02 };
    const b: sizing_types.AirfoilData = .{ .clmax = 1.2, .cd0 = 0.01 };
    const r = blendAirfoils(a, b, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 1.6), r.clmax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.015), r.cd0, 1e-12);
    try testing.expect(blendAirfoils(a, b, 0.3).clmax > r.clmax); // afilada: a raiz pesa mais
    try testing.expectEqual(a, blendAirfoils(a, a, 0.4));
}

test "curva sustentada e teto: contas fechadas" {
    const p: Polar = .{ .CD0 = 0.04, .K = 0.05, .CLmax = 1.4, .CLg = 0.5 };
    const T0 = 30.0;
    const c = linearCurve(T0, 1e9); // tração constante
    const W = 100.0;
    const Sw = 1.0;
    const rho = 1.2;
    const V = 14.0;
    const q = 0.5 * rho * V * V;
    const n = @sqrt(q / (p.K * W) * (T0 / W - q * p.CD0 / W));
    try testing.expectApproxEqRel(@min(n, q * p.CLmax / W), sustainedN(p, &c, W, Sw, rho, V), 1e-12);
    // teto: com tração ∝ ρ, a subida cai com a altitude e o teto passa da altitude do campo
    const h = ceiling(p, &c, W, Sw, rho, 0.5);
    try testing.expect(h > isaAltitude(rho));
    try testing.expectApproxEqAbs(@as(f64, 600), isaAltitude(isaRho(600)), 1e-6);
    try testing.expectApproxEqRel(1.15 * 1.15 * W / (rho * p.CLmax * g0 * 0.3), landingRun(p, W, Sw, rho, 0.3), 1e-12);
}

test "decolagem sem arrasto nem atrito: x = v²·m/(2T)" {
    const p: Polar = .{ .CD0 = 0, .K = 0, .CLmax = 1.5, .CLg = 0 };
    const c = linearCurve(20, 1e9); // tração constante
    const m = 5.0;
    const v_lof = 1.1 * stallSpeed(p, m * g0, 0.8, 1.2);
    const x = takeoffRun(p, &c, m, 0.8, 1.2, 0, 0);
    try testing.expectApproxEqRel(v_lof * v_lof * m / (2 * 20.0), x, 1e-6);
}

test "envelope com tração constante: V_max analítica" {
    const p: Polar = .{ .CD0 = 0.04, .K = 0.05, .CLmax = 1.4, .CLg = 0.5 };
    const T0 = 15.0;
    const c = linearCurve(T0, 1e9);
    const W = 80.0;
    const Sw = 0.8;
    const rho = 1.2;
    const e = envelope(p, &c, W, Sw, rho);
    // T = q S CD0 + K W²/(q S)  →  q = (T + √(T² − 4 CD0 K W²)) / (2 S CD0)
    const q = (T0 + @sqrt(T0 * T0 - 4 * p.CD0 * p.K * W * W)) / (2 * Sw * p.CD0);
    try testing.expectApproxEqRel(@sqrt(2 * q / rho), e.Vmax, 0.02); // interpolação linear na grade
}

fn fuzzStages(_: void, src: *fuzz.Src) !void {
    const cfg: sizing_types.SizingCfg = .{ .oswald = src.range(0.3, 1), .clmax_factor = src.range(0.5, 1), .cl_ground = src.range(0, 1), .fuselage_CDS = src.range(0, 0.05) };
    const af: sizing_types.AirfoilData = .{ .clmax = src.range(0.8, 2.4), .cd0 = src.range(0.005, 0.03) };
    inline for (kinds.all) |K| {
        const geo = geometry(K, src.range(0.3, 5), src.range(0.05, 3));
        const p = polar(K, &cfg, geo, af, src.range(0, 0.02));
        try testing.expect(p.CD0 > 0 and p.K > 0 and p.CLmax > 0 and p.CLg <= p.CLmax);
        const c = linearCurve(src.range(0, 200), src.range(5, 80));
        const m = src.range(0.2, 40);
        const rho = src.range(0.7, 1.3);
        const e = envelope(p, &c, m * g0, geo.S, rho);
        errdefer std.debug.print("K={s} Vs={d} Vmax={d} CD0={d} K={d}\n", .{ K.name, e.Vs, e.Vmax, p.CD0, p.K });
        try testing.expect(e.Vs > 0 and std.math.isFinite(e.Vs));
        if (std.math.isFinite(e.Vmax)) try testing.expect(e.Vmax >= e.Vs - 1e-9);
        // corrida: não negativa e não diminui com a massa
        // curva e teto: finitos ou NaN, nunca negativos; o pouso cresce com a massa
        const nt = sustainedN(p, &c, m * g0, geo.S, rho, 1.4 * e.Vs);
        try testing.expect(!(nt < 0));
        const hc = ceiling(p, &c, m * g0, geo.S, rho, 0.5);
        try testing.expect(std.math.isNan(hc) or hc >= isaAltitude(rho) - 1e-6);
        try testing.expect(landingRun(p, 1.2 * m * g0, geo.S, rho, 0.3) > landingRun(p, m * g0, geo.S, rho, 0.3));
        const s1 = takeoffRun(p, &c, m, geo.S, rho, cfg.mu, 0);
        const s2 = takeoffRun(p, &c, m * 1.2, geo.S, rho, cfg.mu, 0);
        errdefer std.debug.print("s1={d} s2={d} m={d}\n", .{ s1, s2, m });
        try testing.expect(!(s1 < 0) and !(s2 < s1 - 1e-6));
        const ms = emptyMass(K, &cfg, geo, src.range(0, 2), @floor(src.range(1, 4)));
        try testing.expect(ms.pv > 0 and std.math.isFinite(ms.pv));
    }
}

test "fuzz: estágios com tração mock (todas as formas de aeronave)" {
    try fuzz.check({}, fuzzStages, .{});
}
