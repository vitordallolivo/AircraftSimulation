//! Envelope de voo por altitude (sem integrar no tempo).
//!
//! Para cada altitude h (passo h_step) calcula ρ(h) e procura onde a tração disponível cruza a
//! requerida (P_d = P_r): V_min e V_max. Também V_e (estol), V* = V_e √n e V_cru. O teto absoluto
//! é a altitude em que V_min e V_max se encontram (refinado por bisseção em h).
//!
//! Dois métodos:
//!   planilha  (method 0) — as fórmulas do Envelope_main original (polar parabólica com C_Dp e K
//!             da planilha, ângulo de cruzeiro fixo). `faithful = 1` reproduz o original
//!             exatamente (inclusive ρ/ρ0 no lugar de ρ no arrasto); `faithful = 0` usa ρ.
//!   modelo    (method 1) — trimagem completa da aeronave (painéis, momentos, profundor) em cada
//!             (h, V): o acelerador de equilíbrio cruza 1 em V_min e V_max.
//! A tração disponível é a das unidades propulsoras (polinômio ou motor+hélice) com ρ(h).
//!
//! `below_stall = 1` (modelo, desligado por padrão): abaixo do estol a trimagem usa uma cópia dos parâmetros sem
//! estol (C_L linear de cada painel, ângulo de estol a0 levado para longe), só para achar onde P_d = P_r e ver a
//! curva de potência inteira, como a planilha faz com a polar parabólica. Esse trecho não é voável: o V_min de
//! potência pode ficar abaixo do V_e, e o mínimo voável é max(V_min, V_e) (Anderson, Aircraft Performance and
//! Design, cap. 5; a conferir no PDF).
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const state = @import("state.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const prop = @import("../physics/propulsion.zig");
const aero = @import("../physics/aero.zig");
const trim = @import("trim.zig");

pub const method_sheet = 0;
pub const method_model = 1;
pub const atmos_isa = 0;
pub const atmos_sheet = 1;

/// a configuração do envelope: método, atmosfera, faixas de h e V e os dados da planilha
pub const EnvCfg = extern struct {
    method: i32 = method_sheet,
    atmos: i32 = atmos_isa,
    faithful: i32 = 1, // planilha: 1 = arrasto com ρ/ρ0 como no original
    _pad: i32 = 0,
    h_step: f64 = 50,
    h_max: f64 = 8000,
    V_lo: f64 = 4,
    V_hi: f64 = 30,
    dV: f64 = 0.05, // grade para achar os cruzamentos (depois bisseção até tol)
    tol: f64 = 1e-5,
    rho0: f64 = 1.225,
    n_load: f64 = 2,
    alpha_cruise: f64 = 0, // rad
    // dados da planilha (método 0)
    Sw: f64 = 1,
    CLa_w: f64 = 4.5,
    CL0_w: f64 = 0.3,
    CLmax_w: f64 = 1.4,
    iw: f64 = 0,
    Sh: f64 = 0.2,
    CLa_h: f64 = 4,
    CL0_h: f64 = 0,
    CLmax_h: f64 = 1,
    ih: f64 = 0,
    depsda: f64 = 0.4,
    eps0: f64 = 0,
    cdp_x: f64 = 12, // C_Dp = c1 · cdp_x + c2 (como no código original)
    cdpw_c1: f64 = 0,
    cdpw_c2: f64 = 0.012,
    cdph_c1: f64 = 0,
    cdph_c2: f64 = 0.012,
    K: f64 = 0.05,
    below_stall: i32 = 0, // modelo: 1 = continua abaixo do estol com a polar sem estol (ver o topo)
    _pad2: i32 = 0,
};

/// uma linha do envelope: h, ρ, V_min, V_max, V_e, V*, V_cru e a tração máxima
pub const EnvRow = extern struct {
    h: f64 = 0,
    rho: f64 = 0,
    Vmin: f64 = 0,
    Vmax: f64 = 0,
    Ve: f64 = 0,
    Vman: f64 = 0,
    Vcru: f64 = 0,
    Td_max: f64 = 0, // maior tração disponível na faixa de V
    ok: f64 = 0,
};

/// densidade com a altitude
pub fn density(cfg: *const EnvCfg, height: f64) f64 {
    const lam = 0.0065;
    const Rg = 287.053;
    const T0 = 288.15;
    return if (cfg.atmos == atmos_sheet)
        // expressão do Envelope_main original
        cfg.rho0 * fmath.pow(1.0 + lam * height / T0, -limits.g0 / (lam * Rg) - 1.0)
    else
        // ISA, troposfera
        cfg.rho0 * fmath.pow(@max(1.0 - lam * height / T0, 1e-6), limits.g0 / (lam * Rg) - 1.0);
}

/// contexto de uma altitude: cópia dos parâmetros com ρ(h)
const Alt = struct {
    params: types.Params,
    weight: f64,
    rho: f64,
    Vstall: f64 = 0, // modelo: abaixo disso nem tenta trimar
    raw: bool = false, // "como na planilha": polinômio sem o corte em T ≥ 0
    below: bool = false, // modelo com below_stall: abaixo do estol trima em `plin`
    plin: types.Params = undefined, // cópia de `params` sem estol (só com `below`)

    /// tração disponível com acelerador cheio a `airspeed`, somando as unidades
    fn thrust(self: *const Alt, airspeed: f64) f64 {
        var Td: f64 = 0;
        for (self.params.prop[0..@intCast(self.params.n_prop)]) |*prop_unit| {
            Td += if (self.raw and prop_unit.model == types.prop_poly) prop.polyRaw(&self.params, prop_unit, airspeed, 1.0, 0) else prop.point(&self.params, prop_unit, airspeed, 1.0).T;
        }
        return Td;
    }
};

// ---------------------------------------------------------------- método da planilha
/// arrasto pela polar parabólica da planilha
fn sheetDrag(cfg: *const EnvCfg, alt: *const Alt, airspeed: f64, Td: f64) f64 {
    const sa = fmath.sincos(cfg.alpha_cruise);
    const Cl = (alt.weight - Td * sa.s) / (0.5 * cfg.Sw * alt.rho * airspeed * airspeed);
    const CDpw = cfg.cdpw_c1 * cfg.cdp_x + cfg.cdpw_c2;
    const CDph = cfg.cdph_c1 * cfg.cdp_x + cfg.cdph_c2;
    const Cd = CDpw + CDph * (cfg.Sh / cfg.Sw) + cfg.K * Cl * Cl;
    const dens = if (cfg.faithful != 0) alt.rho / cfg.rho0 else alt.rho;
    return dens * airspeed * airspeed * cfg.Sw * Cd / (2.0 * sa.c);
}

/// excesso de tração T_d − T_r (mesmo sinal de P_d − P_r)
fn excess(cfg: *const EnvCfg, alt: *const Alt, airspeed: f64, guess: *[3]f64) f64 {
    if (cfg.method == method_sheet) {
        const Td = alt.thrust(airspeed);
        return Td - sheetDrag(cfg, alt, airspeed, Td);
    }
    // modelo completo: 1 − acelerador de equilíbrio (fora do envelope se não trima ou estola)
    if (airspeed < 0.98 * alt.Vstall) return if (alt.below) excessBelow(alt, airspeed, guess) else -1.0;
    const tc = trim.Ctx.init(&alt.params, &no_flags);
    const tp = trim.solve(tc, types.trim_level, airspeed, 1.0, guess);
    if (tp.ok == 0 or tp.ratioCL > 1.0) {
        guess.* = .{ 0.1, -0.05, 0.5 };
        return if (alt.below) excessBelow(alt, airspeed, guess) else -1.0;
    }
    return 1.0 - tp.thr;
}

/// abaixo do estol (só com `below`): o mesmo equilíbrio na polar sem estol
fn excessBelow(alt: *const Alt, airspeed: f64, guess: *[3]f64) f64 {
    const tp = trim.solve(trim.Ctx.init(&alt.plin, &no_flags), types.trim_level, airspeed, 1.0, guess);
    if (tp.ok == 0) {
        guess.* = .{ 0.1, -0.05, 0.5 };
        return -1.0;
    }
    return 1.0 - tp.thr;
}

/// cópia dos parâmetros sem estol: o a0 de cada painel vai para longe e o C_L fica na reta (aero.clPanel)
fn noStall(params: *const types.Params) types.Params {
    var copy = params.*;
    const n_surf: usize = @intCast(copy.n_surf);
    for (copy.surf[0..n_surf]) |*surface| surface.a0 = 10.0;
    return copy;
}

const no_flags = state.Flags{ .released = 0 };

/// bisseção em V entre lo0 e hi0 até o excesso de tração trocar de sinal
fn bisect(cfg: *const EnvCfg, alt: *const Alt, lo0: f64, hi0: f64) f64 {
    var lo = lo0;
    var hi = hi0;
    var guess = [3]f64{ 0.1, -0.05, 0.5 };
    const flo = excess(cfg, alt, lo, &guess) > 0;
    // a trimagem converge a ~1e-9; abaixo de 1e-3 m/s não muda nada no modelo completo
    const tol = if (cfg.method == method_model) @max(cfg.tol, 1e-3) else @max(cfg.tol, 1e-10);
    var it: usize = 0;
    while (hi - lo > tol and it < 100) : (it += 1) {
        const mid = 0.5 * (lo + hi);
        if ((excess(cfg, alt, mid, &guess) > 0) == flo) lo = mid else hi = mid;
    }
    return 0.5 * (lo + hi);
}

/// os cruzamentos achados numa altitude e a maior tração disponível
const Cross = struct { vmin: f64, vmax: f64, any: bool, Td_max: f64 };

/// procura na grade os cruzamentos e refina: V_min (− → +) e V_max (+ → −)
fn crossings(cfg: *const EnvCfg, alt: *const Alt) Cross {
    var out = Cross{ .vmin = 0, .vmax = 0, .any = false, .Td_max = 0 };
    var guess = [3]f64{ 0.1, -0.05, 0.5 };
    // de cima para baixo: o chute da trimagem vem do ponto anterior
    var airspeed = cfg.V_hi;
    var f_prev = excess(cfg, alt, airspeed, &guess);
    var have_max = false;
    var first_pos_low: f64 = -1;
    out.Td_max = alt.thrust(airspeed);
    if (f_prev > 0) {
        out.vmax = cfg.V_hi; // ainda sobra tração no fim da faixa
        have_max = true;
    }
    while (airspeed - cfg.dV >= cfg.V_lo - 1e-12) {
        const Vn = airspeed - cfg.dV;
        const excess_now = excess(cfg, alt, Vn, &guess);
        out.Td_max = @max(out.Td_max, alt.thrust(Vn));
        if (excess_now > 0 and f_prev <= 0 and !have_max) {
            out.vmax = bisect(cfg, alt, Vn, airspeed);
            have_max = true;
        }
        if (excess_now <= 0 and f_prev > 0 and have_max) {
            out.vmin = bisect(cfg, alt, Vn, airspeed);
            out.any = true;
            return out;
        }
        if (excess_now > 0) first_pos_low = Vn;
        f_prev = excess_now;
        airspeed = Vn;
    }
    if (have_max and first_pos_low > 0) { // sobra tração até o começo da faixa
        out.vmin = cfg.V_lo;
        out.any = true;
    }
    return out;
}

/// o contexto da altitude `height`: ρ, cópia dos parâmetros e, no modelo, o V de estol
fn altitude(params: *const types.Params, cfg: *const EnvCfg, height: f64, weight: f64, CLmax_ac: f64) Alt {
    var alt = Alt{ .params = params.*, .weight = weight, .rho = density(cfg, height), .raw = cfg.method == method_sheet and cfg.faithful != 0 };
    alt.params.env.rho = alt.rho;
    if (cfg.method == method_model) alt.Vstall = @sqrt(2.0 * weight / (alt.rho * params.Sref * CLmax_ac));
    if (cfg.method == method_model and cfg.below_stall != 0) {
        alt.below = true;
        alt.plin = noStall(&alt.params);
    }
    return alt;
}

/// a linha do envelope na altitude `height`
fn row(params: *const types.Params, cfg: *const EnvCfg, height: f64, weight: f64, CLmax_ac: f64, alt: *Alt) EnvRow {
    alt.* = altitude(params, cfg, height, weight, CLmax_ac);
    var result = EnvRow{ .h = height, .rho = alt.rho };
    const cross = crossings(cfg, alt);
    result.Td_max = cross.Td_max;
    result.ok = if (cross.any) 1 else 0;
    result.Vmin = cross.vmin;
    result.Vmax = cross.vmax;
    if (cfg.method == method_sheet) {
        result.Ve = @sqrt(2.0 * weight / (alt.rho * (cfg.Sw * cfg.CLmax_w + cfg.Sh * cfg.CLmax_h)));
        const alphah = cfg.alpha_cruise * (1.0 - cfg.depsda) - cfg.eps0 + cfg.ih;
        const CLw = cfg.CL0_w + cfg.CLa_w * (cfg.iw + cfg.alpha_cruise);
        const CLh = -cfg.CL0_h + cfg.CLa_h * alphah;
        const Td_end = alt.thrust(cfg.V_hi);
        result.Vcru = @sqrt(@abs(2.0 * (weight - Td_end * fmath.sin(cfg.alpha_cruise)) / (alt.rho * (cfg.Sw * CLw + cfg.Sh * CLh))));
    } else {
        result.Ve = alt.Vstall;
        result.Vcru = if (cross.any) cruiseSpeed(cfg, alt, cross.vmin, cross.vmax) else std.math.nan(f64);
    }
    result.Vman = result.Ve * @sqrt(cfg.n_load);
    return result;
}

/// modelo completo: V (dentro do envelope) em que o α de equilíbrio é o ângulo de cruzeiro
fn cruiseSpeed(cfg: *const EnvCfg, alt: *const Alt, Vlo: f64, Vhi: f64) f64 {
    const tc = trim.Ctx.init(&alt.params, &no_flags);
    const Fn = struct {
        fn alphaError(trim_ctx: trim.Ctx, airspeed: f64, target_alpha: f64) ?f64 {
            var guess = [3]f64{ 0.1, -0.05, 0.5 };
            const tp = trim.solve(trim_ctx, types.trim_level, airspeed, 1.0, &guess);
            return if (tp.ok != 0) tp.alpha - target_alpha else null;
        }
    };
    var lo = Vlo + 1e-3;
    var hi = Vhi - 1e-3;
    // com `below`, o V_min pode estar abaixo do estol, onde a trimagem normal não existe: a busca começa no
    // primeiro V (a partir do V_e) em que ela converge
    if (alt.below and lo < alt.Vstall) {
        lo = alt.Vstall;
        while (lo < hi and Fn.alphaError(tc, lo, cfg.alpha_cruise) == null) lo += 0.05;
    }
    const alo = Fn.alphaError(tc, lo, cfg.alpha_cruise) orelse return std.math.nan(f64);
    const ahi = Fn.alphaError(tc, hi, cfg.alpha_cruise) orelse return std.math.nan(f64);
    if ((alo > 0) == (ahi > 0)) return std.math.nan(f64); // ângulo de cruzeiro fora do envelope
    var it: usize = 0;
    while (hi - lo > 1e-3 and it < 60) : (it += 1) {
        const mid = 0.5 * (lo + hi);
        const alpha_error = Fn.alphaError(tc, mid, cfg.alpha_cruise) orelse return std.math.nan(f64);
        if ((alpha_error > 0) == (alo > 0)) lo = mid else hi = mid;
    }
    return 0.5 * (lo + hi);
}

/// C_L máximo da aeronave inteira (polar estática, profundor neutro)
fn aircraftCLmax(params: *const types.Params, rcg: vec.V3) f64 {
    var best: f64 = 0;
    var al: f64 = 0;
    while (al < 0.6) : (al += 0.002) best = @max(best, aero.coeffs(params, 15.0, al, 0, rcg, vec.zero).CL);
    return best;
}

/// linhas por altitude; devolve quantas e o teto absoluto (refinado por bisseção em h)
pub fn compute(params: *const types.Params, cfg: *const EnvCfg, rows: []EnvRow, ceiling: *f64) usize {
    const tc = trim.Ctx.init(params, &no_flags);
    const weight = tc.m * limits.g0;
    const CLmax_ac = aircraftCLmax(params, tc.rcg);
    var alt: Alt = undefined;
    var count: usize = 0;
    var height: f64 = 0;
    ceiling.* = 0;
    while (count < rows.len and height <= cfg.h_max) : (height += cfg.h_step) {
        const result = row(params, cfg, height, weight, CLmax_ac, &alt);
        if (result.ok == 0 or result.Vmax - result.Vmin < cfg.tol) {
            // teto entre h − h_step e h
            var lo = @max(height - cfg.h_step, 0.0);
            var hi = height;
            if (count == 0) return 0;
            var it: usize = 0;
            while (hi - lo > 0.5 and it < 60) : (it += 1) {
                const mid = 0.5 * (lo + hi);
                alt = altitude(params, cfg, mid, weight, CLmax_ac);
                const cross = crossings(cfg, &alt);
                if (cross.any and cross.vmax - cross.vmin >= cfg.tol) lo = mid else hi = mid;
            }
            ceiling.* = lo;
            return count;
        }
        rows[count] = result;
        count += 1;
        ceiling.* = height;
    }
    return count;
}

/// curvas T_d(V) e T_r(V) na altitude `height`, nos V de `speeds` (para os gráficos de potência)
pub fn curve(params: *const types.Params, cfg: *const EnvCfg, height: f64, speeds: []f64, Td: []f64, Tr: []f64) usize {
    const tc = trim.Ctx.init(params, &no_flags);
    const alt = altitude(params, cfg, height, tc.m * limits.g0, aircraftCLmax(params, tc.rcg));
    const count = @min(speeds.len, @min(Td.len, Tr.len));
    var guess = [3]f64{ 0.1, -0.05, 0.5 };
    var i: usize = count;
    while (i > 0) { // de cima para baixo (chute da trimagem)
        i -= 1;
        const airspeed = cfg.V_lo + (cfg.V_hi - cfg.V_lo) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(count, 2) - 1));
        speeds[i] = airspeed;
        Td[i] = alt.thrust(airspeed);
        if (cfg.method == method_sheet) {
            Tr[i] = sheetDrag(cfg, &alt, airspeed, Td[i]);
        } else {
            // tração requerida = tração no equilíbrio nivelado
            var tp = trim.solve(trim.Ctx.init(&alt.params, &no_flags), types.trim_level, airspeed, 1.0, &guess);
            if (alt.below and (airspeed < 0.98 * alt.Vstall or tp.ok == 0 or tp.ratioCL > 1.0)) {
                if (tp.ok == 0) guess = .{ 0.1, -0.05, 0.5 };
                tp = trim.solve(trim.Ctx.init(&alt.plin, &no_flags), types.trim_level, airspeed, 1.0, &guess);
            }
            Tr[i] = if (tp.ok != 0) tp.T else std.math.nan(f64);
            if (tp.ok == 0) guess = .{ 0.1, -0.05, 0.5 };
        }
    }
    return count;
}

const testing = std.testing;

test "ISA e a fórmula da planilha" {
    const isa = EnvCfg{};
    const sh = EnvCfg{ .atmos = atmos_sheet };
    try testing.expectApproxEqRel(@as(f64, 1.225 * 0.9075), density(&isa, 1000), 2e-3);
    try testing.expectApproxEqRel(@as(f64, 1.225 * 0.8698), density(&sh, 1000), 2e-3);
    try testing.expectEqual(@as(f64, 1.225), density(&isa, 0));
}

test "envelope da planilha: V_min < V_max, teto finito, ρ cai" {
    var params = types.Params{ .m_dry = 8.0, .Sref = 0.6 };
    params.n_prop = 1;
    params.prop[0] = .{ .model = types.prop_poly, .poly_x = types.pvar_V, .poly_gain = 1, .poly_rho_exp = 1 };
    params.prop[0].poly[0] = 25; // T(V) = 25 − 0,04 V²
    params.prop[0].poly[3] = -0.04;
    prop.init(&params);
    const cfg = EnvCfg{ .Sw = 0.6, .CLmax_w = 1.4, .K = 0.06, .cdpw_c2 = 0.03, .cdph_c2 = 0.01, .faithful = 0, .h_step = 250, .dV = 0.1 };
    var rows: [200]EnvRow = undefined;
    var ceil: f64 = 0;
    const count = compute(&params, &cfg, &rows, &ceil);
    try testing.expect(count > 2);
    try testing.expect(ceil > 0 and ceil < cfg.h_max);
    for (rows[0..count]) |result| try testing.expect(result.Vmin < result.Vmax);
    try testing.expect(rows[count - 1].rho < rows[0].rho);
    try testing.expect(rows[count - 1].Vmax - rows[count - 1].Vmin < rows[0].Vmax - rows[0].Vmin);
}

test "sem estol (below_stall): a cópia mantém o C_L na reta depois do estol do original" {
    var params = types.Params{ .m_dry = 8.0, .Sref = 0.6 };
    params.n_surf = 1;
    params.surf[0].CL0 = 0.3;
    params.surf[0].CLa = 5.0;
    params.surf[0].a0 = 0.25; // estol do original em ~14°
    const copy = noStall(&params);
    try testing.expectEqual(@as(f64, 0.25), params.surf[0].a0); // o original não muda
    try testing.expectEqual(@as(f64, 10.0), copy.surf[0].a0);
    const al: f64 = 0.4; // depois do estol do original
    const cl = aero.sigmaStall(al, copy.surf[0].a0, 50.0);
    try testing.expect(cl < 1e-6); // a mistura com a placa plana some: só a reta
    try testing.expect(aero.sigmaStall(al, params.surf[0].a0, 50.0) > 0.99);
}
