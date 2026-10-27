//! K unidades propulsoras: hélice por tabela C_T(J), C_P(J) + motor BLDC + bateria.
//!
//!   J = V_p / (n D),  V_p = (V_ar + ω × r_p) · e_T
//!   T = C_T ρ n² D⁴,  Q = C_P/(2π) ρ n² D⁵
//!   I = (u V_oc − K_e ω) / (R_m + u² R_int)      (u: acelerador)
//!   (J_m + I_p) 2π dn/dt = K_e I − B ω − τ_c − Q
//! Força T e_T no cubo; momento r × F − sentido Q e_T; giroscópico −ω × H.
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

/// estado de uma unidade: tração, torque, avanço J, correntes, tensão, potência e dn/dt
pub const Unit = struct {
    T: f64 = 0,
    Q: f64 = 0,
    J: f64 = 0,
    I: f64 = 0,
    Ibat: f64 = 0,
    Vbus: f64 = 0,
    P: f64 = 0,
    drps: f64 = 0,
};

/// a soma das unidades (força, momento, giroscópico) e o estado de cada uma
pub const Out = struct {
    F: V3 = vec.zero,
    M: V3 = vec.zero,
    Mgyro: V3 = vec.zero,
    T: f64 = 0,
    Q: f64 = 0,
    P: f64 = 0,
    Ibat: f64 = 0,
    Vbus: f64 = 0,
    T_sin: f64 = 0, // Σ T_i sin(θ + tilt_i), para as reações do artigo
    u: [limits.max_props]Unit = undefined, // só as n_prop primeiras são escritas e lidas
};

/// eixo de tração, D⁴, D⁵ e K_e de cada unidade, calculados uma vez
pub fn init(params: *types.Params) void {
    const n_props: usize = @intCast(params.n_prop);
    for (params.prop[0..n_props]) |*prop_unit| {
        const tilt = fmath.sincos(prop_unit.tilt);
        const toe = fmath.sincos(prop_unit.toe);
        prop_unit.eT = .{ tilt.c * toe.c, tilt.c * toe.s, -tilt.s };
        prop_unit.D4 = prop_unit.D * prop_unit.D * prop_unit.D * prop_unit.D;
        prop_unit.D5 = prop_unit.D4 * prop_unit.D;
        prop_unit.Ke = 60.0 / (2.0 * fmath.pi * prop_unit.Kv);
    }
}

/// C_T e C_P no avanço `advance` (J) por interpolação linear na tabela (busca binária: tabela monotônica em J)
fn coef(prop_unit: *const types.PropUnit, advance: f64, CT: *f64, CP: *f64) void {
    @setFloatMode(fmath.float_mode);
    const count: usize = @intCast(prop_unit.n_pts);
    if (count < 2) {
        CT.* = 0;
        CP.* = 0.002;
        return;
    }
    if (advance <= prop_unit.J[0]) {
        CT.* = prop_unit.CT[0];
        CP.* = prop_unit.CP[0];
        return;
    }
    var lo: usize = 0;
    var hi: usize = count - 1;
    if (advance >= prop_unit.J[hi]) {
        lo = hi - 1;
    } else while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (prop_unit.J[mid] < advance) lo = mid else hi = mid;
    }
    const upper = lo + 1;
    const fraction = (advance - prop_unit.J[upper - 1]) / (prop_unit.J[upper] - prop_unit.J[upper - 1]);
    CT.* = prop_unit.CT[upper - 1] + fraction * (prop_unit.CT[upper] - prop_unit.CT[upper - 1]);
    CP.* = @max(0.002, prop_unit.CP[upper - 1] + fraction * (prop_unit.CP[upper] - prop_unit.CP[upper - 1]));
}

/// o valor da variável `code` do polinômio de tração (V, acelerador, altura, densidade ou constante)
fn polyVar(code: i32, constant: f64, airspeed: f64, thr: f64, height: f64, rho: f64) f64 {
    return switch (code) {
        types.pvar_V => airspeed,
        types.pvar_throttle => thr,
        types.pvar_h => height,
        types.pvar_rho => rho,
        types.pvar_const => constant,
        else => 0.0,
    };
}

/// `value` limitado a [0, max_value] (max_value ≤ 0: sem limite)
inline fn clampRange(value: f64, max_value: f64) f64 {
    return if (max_value > 0) fmath.lim(value, 0.0, max_value) else value;
}

/// valor do polinômio sem o corte em T ≥ 0 (o envelope "como na planilha" usa assim)
pub fn polyRaw(params: *const types.Params, prop_unit: *const types.PropUnit, airspeed: f64, thr: f64, height: f64) f64 {
    const rho = params.env.rho;
    const x_value = clampRange(polyVar(prop_unit.poly_x, prop_unit.poly_xc, airspeed, thr, height, rho), prop_unit.poly_xmax);
    const y_value = clampRange(polyVar(prop_unit.poly_y, prop_unit.poly_yc, airspeed, thr, height, rho), prop_unit.poly_ymax);
    var Tp = prop_unit.poly_gain * types.ThrustPoly.eval(&prop_unit.poly, x_value, y_value);
    if (prop_unit.poly_rho_exp != 0) Tp *= fmath.pow(rho / prop_unit.poly_rho0, prop_unit.poly_rho_exp);
    if (prop_unit.poly_x != types.pvar_throttle and prop_unit.poly_y != types.pvar_throttle) Tp *= thr;
    return Tp;
}

/// tração polinomial (sem motor, bateria nem rotação)
fn polyUnit(params: *const types.Params, prop_unit: *const types.PropUnit, eT: V3, Vr: V3, body_rates: V3, thr: f64, height: f64) Unit {
    const axial_speed = vec.dot(Vr + vec.cross(body_rates, vec.v3(prop_unit.r)), eT);
    return .{ .T = @max(polyRaw(params, prop_unit, axial_speed, thr, height), 0.0) };
}

/// inclinação atual do eixo (rad): fixa, ou tilt + comando·tilt_range no eixo móvel
pub fn tiltNow(params: *const types.Params, prop_unit: *const types.PropUnit) f64 {
    if (prop_unit.tilt_range == 0) return prop_unit.tilt;
    const command = if (std.math.isFinite(params.pilot.tilt)) fmath.lim(params.pilot.tilt, 0.0, 1.0) else 0.0;
    return prop_unit.tilt + command * prop_unit.tilt_range;
}

/// eixo de tração atual (corpo)
pub fn axis(params: *const types.Params, prop_unit: *const types.PropUnit) V3 {
    if (prop_unit.tilt_range == 0) return vec.v3(prop_unit.eT);
    const tilt = fmath.sincos(tiltNow(params, prop_unit));
    const toe = fmath.sincos(prop_unit.toe);
    return .{ tilt.c * toe.c, tilt.c * toe.s, -tilt.s };
}

/// estado da unidade com rotação `rps` e acelerador `thr`: hélice pela tabela, motor e bateria
pub fn unit(params: *const types.Params, prop_unit: *const types.PropUnit, eT: V3, Vr: V3, body_rates: V3, rps: f64, thr: f64, height: f64) Unit {
    @setFloatMode(fmath.float_mode);
    if (prop_unit.model == types.prop_poly) return polyUnit(params, prop_unit, eT, Vr, body_rates, thr, height);
    var out = Unit{};
    const rps_used = if (rps > 1.0) rps else 1.0;
    const wm = 2.0 * fmath.pi * rps_used;
    const inflow = Vr + vec.cross(body_rates, vec.v3(prop_unit.r));
    out.J = vec.dot(inflow, eT) / (rps_used * prop_unit.D);
    var CT: f64 = 0;
    var CP: f64 = 0;
    coef(prop_unit, out.J, &CT, &CP);
    const rn2 = params.env.rho * rps_used * rps_used;
    out.T = CT * rn2 * prop_unit.D4;
    out.Q = CP / (2.0 * fmath.pi) * rn2 * prop_unit.D5;
    out.I = fmath.lim((thr * prop_unit.Voc - prop_unit.Ke * wm) / (prop_unit.Rm + thr * thr * prop_unit.Rint), 0.0, prop_unit.Imax);
    out.Ibat = thr * out.I;
    out.Vbus = prop_unit.Voc - prop_unit.Rint * out.Ibat;
    out.P = out.Vbus * out.Ibat;
    out.drps = (prop_unit.Ke * out.I - prop_unit.B * wm - prop_unit.tauc - out.Q) / (2.0 * fmath.pi * (prop_unit.Jm + prop_unit.Ip));
    return out;
}

/// força e momento de todos os motores; rps: rotação de cada unidade (vem do vetor de estados); dr: leme
/// (acelerador diferencial)
pub fn compute(params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, rps: []const f64, thr: f64, dr: f64, theta: f64, height: f64) Out {
    // campo a campo: `Out{}` zeraria as 8 unidades (~600 B) a cada chamada
    var out: Out = undefined;
    out.F = vec.zero;
    out.M = vec.zero;
    out.Mgyro = vec.zero;
    out.T = 0;
    out.Q = 0;
    out.P = 0;
    out.Ibat = 0;
    out.Vbus = 0;
    out.T_sin = 0;
    const n_props: usize = @intCast(params.n_prop);
    for (params.prop[0..n_props], 0..) |*prop_unit, i| {
        // o piloto já limita thr a [0, 1]; aqui só a mistura de guinada é limitada. A trimagem pode
        // pedir thr > 1 ("precisa de mais que o máximo"), como no simulador original.
        const th = fmath.lim(thr + prop_unit.yaw_mix * dr, 0.0, @max(1.0, thr));
        const eT = axis(params, prop_unit);
        const result = unit(params, prop_unit, eT, Vr, body_rates, rps[i], th, height);
        out.u[i] = result;
        const force = eT * vec.splat(result.T);
        out.F += force;
        out.M += vec.cross(vec.v3(prop_unit.r) - rcg, force) - eT * vec.splat(prop_unit.sense * result.Q);
        const wm = 2.0 * fmath.pi * @max(rps[i], 1.0);
        const momentum = eT * vec.splat(prop_unit.sense * (prop_unit.Ip + prop_unit.Jm) * wm);
        out.Mgyro -= vec.cross(body_rates, momentum);
        out.T += result.T;
        out.Q += result.Q;
        out.P += result.P;
        out.Ibat += result.Ibat;
        out.Vbus = if (i == 0) result.Vbus else @min(out.Vbus, result.Vbus);
        out.T_sin += result.T * fmath.sin(theta + tiltNow(params, prop_unit));
    }
    return out;
}

/// rotação de equilíbrio (dn/dt = 0), sem rotação do avião. dn/dt cai com n, então a raiz é
/// única em [1, 600] rps: regula falsi com a modificação de Illinois (converge em ~10 passos).
pub fn equilibriumRps(params: *const types.Params, prop_unit: *const types.PropUnit, Vr: V3, thr: f64) f64 {
    @setFloatMode(fmath.float_mode);
    if (prop_unit.model == types.prop_poly) return 1.0;
    var rps_low: f64 = 1.0;
    var rps_high: f64 = 600.0;
    var rate_low = unit(params, prop_unit, vec.v3(prop_unit.eT), Vr, vec.zero, rps_low, thr, 0).drps;
    if (rate_low <= 0.0) return rps_low;
    var rate_high = unit(params, prop_unit, vec.v3(prop_unit.eT), Vr, vec.zero, rps_high, thr, 0).drps;
    if (rate_high >= 0.0) return rps_high;
    var side: i32 = 0;
    for (0..80) |_| {
        const rps_mid = (rps_low * rate_high - rps_high * rate_low) / (rate_high - rate_low);
        const rate_mid = unit(params, prop_unit, vec.v3(prop_unit.eT), Vr, vec.zero, rps_mid, thr, 0).drps;
        if (@abs(rate_mid) < 1e-9 or rps_high - rps_low < 1e-10 * rps_high) return rps_mid;
        if ((rate_mid > 0) == (rate_low > 0)) {
            rps_low = rps_mid;
            rate_low = rate_mid;
            if (side == -1) rate_high *= 0.5;
            side = -1;
        } else {
            rps_high = rps_mid;
            rate_high = rate_mid;
            if (side == 1) rate_low *= 0.5;
            side = 1;
        }
    }
    return 0.5 * (rps_low + rps_high);
}

/// ponto de operação em voo axial a `airspeed` (curva de tração)
pub fn point(params: *const types.Params, prop_unit: *const types.PropUnit, airspeed: f64, thr: f64) types.PropPoint {
    const Vr = vec.v3(prop_unit.eT) * vec.splat(airspeed);
    const rps = equilibriumRps(params, prop_unit, Vr, thr);
    const result = unit(params, prop_unit, vec.v3(prop_unit.eT), Vr, vec.zero, rps, thr, 0);
    const Ps = result.Q * 2.0 * fmath.pi * rps;
    return .{
        .V = airspeed,
        .rpm = rps * 60.0,
        .J = result.J,
        .T = result.T,
        .Q = result.Q,
        .P_shaft = Ps,
        .P_elec = result.P,
        .I = result.I,
        .eta_prop = if (Ps > 1e-6) result.T * airspeed / Ps else 0,
    };
}

const testing = std.testing;

test "rotação de equilíbrio: dn/dt ≈ 0" {
    var params = types.Params{};
    params.n_prop = 1;
    var prop_unit = &params.prop[0];
    prop_unit.* = .{ .D = 0.381, .Ip = 5.4e-4, .Jm = 1e-4, .Kv = 310, .Rm = 0.0204, .B = 32.4e-6, .tauc = 0.0155, .Imax = 80, .Voc = 22.2, .Rint = 0.035, .n_pts = 2 };
    prop_unit.J[1] = 0.68;
    prop_unit.CT[0] = 0.09;
    prop_unit.CP[0] = 0.03;
    prop_unit.CP[1] = 0.006;
    init(&params);
    inline for (.{ 0.3, 0.7, 1.0 }) |thr| {
        const rps = equilibriumRps(&params, &params.prop[0], .{ 12, 0, 0 }, thr);
        try testing.expect(@abs(unit(&params, &params.prop[0], vec.v3(params.prop[0].eT), .{ 12, 0, 0 }, vec.zero, rps, thr, 0).drps) < 1e-6);
    }
}

test "eixo móvel: comando 0 = eixo fixo; comando 1 = tilt + faixa" {
    var params = types.Params{};
    params.n_prop = 1;
    params.prop[0] = .{ .tilt = 0.05, .tilt_range = std.math.pi / 2.0 - 0.05, .model = types.prop_poly, .poly_x = types.pvar_const, .poly_gain = 1 };
    params.prop[0].poly[0] = 10;
    init(&params);
    const fixed = axis(&params, &params.prop[0]);
    try testing.expectApproxEqAbs(fmath.cos(0.05), fixed[0], 1e-12);
    params.pilot.tilt = 1; // eixo na vertical: a tração vira sustentação (−z)
    const up = axis(&params, &params.prop[0]);
    try testing.expectApproxEqAbs(@as(f64, 0), up[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1), up[2], 1e-12);
    var rps = [_]f64{0} ** limits.max_props;
    const out = compute(&params, .{ 0, 0, 0 }, vec.zero, vec.zero, &rps, 1.0, 0, 0, 0);
    try testing.expectApproxEqAbs(@as(f64, -10), out.F[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), out.F[0], 1e-9);
}

test "tração estática e queda com V" {
    var params = types.Params{};
    params.n_prop = 1;
    var prop_unit = &params.prop[0];
    prop_unit.* = .{ .D = 0.381, .Ip = 5.4e-4, .Jm = 1e-4, .Kv = 310, .Rm = 0.0204, .B = 32.4e-6, .tauc = 0.0155, .Imax = 80, .Voc = 22.2, .Rint = 0.035, .n_pts = 3 };
    prop_unit.J[0] = 0;
    prop_unit.J[1] = 0.35;
    prop_unit.J[2] = 0.68;
    prop_unit.CT[0] = 0.09;
    prop_unit.CT[1] = 0.055;
    prop_unit.CT[2] = 0.0;
    prop_unit.CP[0] = 0.03;
    prop_unit.CP[1] = 0.03;
    prop_unit.CP[2] = 0.006;
    init(&params);
    const first = point(&params, &params.prop[0], 0.0, 1.0);
    const second = point(&params, &params.prop[0], 15.0, 1.0);
    try testing.expect(first.T > 20 and first.T < 80);
    try testing.expect(second.T < first.T);
}

test "tração polinomial: T(V) com acelerador e correção de densidade" {
    var params = types.Params{};
    params.n_prop = 1;
    var prop_unit = &params.prop[0];
    prop_unit.* = .{ .model = types.prop_poly, .poly_x = types.pvar_V, .poly_y = types.pvar_none };
    prop_unit.poly[0] = 30; // p00
    prop_unit.poly[1] = -1; // p10 · V
    prop_unit.poly[3] = -0.02; // p20 · V²
    init(&params);
    const first = point(&params, &params.prop[0], 10.0, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 30 - 10 - 2), first.T, 1e-9);
    const second = point(&params, &params.prop[0], 10.0, 0.5);
    try testing.expectApproxEqAbs(first.T * 0.5, second.T, 1e-9);
    prop_unit.poly_rho_exp = 1.0;
    params.env.rho = 0.6125;
    try testing.expectApproxEqAbs(first.T * 0.5, point(&params, &params.prop[0], 10.0, 1.0).T, 1e-9);
    // fora da faixa do ajuste não fica negativa
    try testing.expectEqual(@as(f64, 0), point(&params, &params.prop[0], 100.0, 1.0).T);
}

test "tração como na planilha: x = n constante, y = V, T0 no lugar de p00, g·ρ/ρ0" {
    var params = types.Params{};
    params.n_prop = 1;
    var prop_unit = &params.prop[0];
    prop_unit.* = .{ .model = types.prop_poly, .poly_x = types.pvar_const, .poly_xc = 2.0, .poly_y = types.pvar_V, .poly_gain = limits.g0, .poly_rho_exp = 1.0, .poly_rho0 = 1.225 };
    prop_unit.poly[0] = 3.0; // T0
    prop_unit.poly[1] = 0.1; // p10 · n
    prop_unit.poly[2] = -0.05; // p01 · V
    prop_unit.poly[4] = 0.01; // p11 · n V
    init(&params);
    params.env.rho = 1.1;
    const airspeed = 8.0;
    const want = limits.g0 * (1.1 / 1.225) * (3.0 + 0.1 * 2.0 - 0.05 * airspeed + 0.01 * 2.0 * airspeed);
    try testing.expectApproxEqAbs(want, point(&params, &params.prop[0], airspeed, 1.0).T, 1e-9);
}

test "tração polinomial com o acelerador como variável y" {
    var params = types.Params{};
    params.n_prop = 1;
    var prop_unit = &params.prop[0];
    prop_unit.* = .{ .model = types.prop_poly, .poly_x = types.pvar_V, .poly_y = types.pvar_throttle };
    prop_unit.poly[2] = 20; // p01 · thr
    init(&params);
    try testing.expectApproxEqAbs(@as(f64, 14), point(&params, &params.prop[0], 5.0, 0.7).T, 1e-9);
}
