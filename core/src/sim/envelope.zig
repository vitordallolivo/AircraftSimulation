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
const L = @import("../limits.zig");
const T = @import("../types.zig");
const S = @import("state.zig");
const fm = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const prop = @import("../physics/propulsion.zig");
const aero = @import("../physics/aero.zig");
const trim = @import("trim.zig");

pub const method_sheet = 0;
pub const method_model = 1;
pub const atmos_isa = 0;
pub const atmos_sheet = 1;

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
pub fn density(cfg: *const EnvCfg, h: f64) f64 {
    const lam = 0.0065;
    const Rg = 287.053;
    const T0 = 288.15;
    return if (cfg.atmos == atmos_sheet)
        // expressão do Envelope_main original
        cfg.rho0 * fm.pow(1.0 + lam * h / T0, -L.g0 / (lam * Rg) - 1.0)
    else
        // ISA, troposfera
        cfg.rho0 * fm.pow(@max(1.0 - lam * h / T0, 1e-6), L.g0 / (lam * Rg) - 1.0);
}

/// contexto de uma altitude: cópia dos parâmetros com ρ(h)
const Alt = struct {
    p: T.Params,
    W: f64,
    rho: f64,
    Vstall: f64 = 0, // modelo: abaixo disso nem tenta trimar
    raw: bool = false, // "como na planilha": polinômio sem o corte em T ≥ 0
    below: bool = false, // modelo com below_stall: abaixo do estol trima em `plin`
    plin: T.Params = undefined, // cópia de `p` sem estol (só com `below`)

    fn thrust(self: *const Alt, V: f64) f64 {
        var Td: f64 = 0;
        for (self.p.prop[0..@intCast(self.p.n_prop)]) |*u| {
            Td += if (self.raw and u.model == T.prop_poly) prop.polyRaw(&self.p, u, V, 1.0, 0) else prop.point(&self.p, u, V, 1.0).T;
        }
        return Td;
    }
};

// ---------------------------------------------------------------- método da planilha
fn sheetDrag(cfg: *const EnvCfg, a: *const Alt, V: f64, Td: f64) f64 {
    const sa = fm.sincos(cfg.alpha_cruise);
    const Cl = (a.W - Td * sa.s) / (0.5 * cfg.Sw * a.rho * V * V);
    const CDpw = cfg.cdpw_c1 * cfg.cdp_x + cfg.cdpw_c2;
    const CDph = cfg.cdph_c1 * cfg.cdp_x + cfg.cdph_c2;
    const Cd = CDpw + CDph * (cfg.Sh / cfg.Sw) + cfg.K * Cl * Cl;
    const dens = if (cfg.faithful != 0) a.rho / cfg.rho0 else a.rho;
    return dens * V * V * cfg.Sw * Cd / (2.0 * sa.c);
}

/// excesso de tração T_d − T_r (mesmo sinal de P_d − P_r)
fn excess(cfg: *const EnvCfg, a: *const Alt, V: f64, guess: *[3]f64) f64 {
    if (cfg.method == method_sheet) {
        const Td = a.thrust(V);
        return Td - sheetDrag(cfg, a, V, Td);
    }
    // modelo completo: 1 − acelerador de equilíbrio (fora do envelope se não trima ou estola)
    if (V < 0.98 * a.Vstall) return if (a.below) excessBelow(a, V, guess) else -1.0;
    const tc = trim.Ctx.init(&a.p, &no_flags);
    const tp = trim.solve(tc, T.trim_level, V, 1.0, guess);
    if (tp.ok == 0 or tp.ratioCL > 1.0) {
        guess.* = .{ 0.1, -0.05, 0.5 };
        return if (a.below) excessBelow(a, V, guess) else -1.0;
    }
    return 1.0 - tp.thr;
}

/// abaixo do estol (só com `below`): o mesmo equilíbrio na polar sem estol
fn excessBelow(a: *const Alt, V: f64, guess: *[3]f64) f64 {
    const tp = trim.solve(trim.Ctx.init(&a.plin, &no_flags), T.trim_level, V, 1.0, guess);
    if (tp.ok == 0) {
        guess.* = .{ 0.1, -0.05, 0.5 };
        return -1.0;
    }
    return 1.0 - tp.thr;
}

/// cópia dos parâmetros sem estol: o a0 de cada painel vai para longe e o C_L fica na reta (aero.clPanel)
fn noStall(p: *const T.Params) T.Params {
    var q = p.*;
    const n: usize = @intCast(q.n_surf);
    for (q.surf[0..n]) |*s| s.a0 = 10.0;
    return q;
}

const no_flags = S.Flags{ .released = 0 };

fn bisect(cfg: *const EnvCfg, a: *const Alt, lo0: f64, hi0: f64) f64 {
    var lo = lo0;
    var hi = hi0;
    var g = [3]f64{ 0.1, -0.05, 0.5 };
    const flo = excess(cfg, a, lo, &g) > 0;
    // a trimagem converge a ~1e-9; abaixo de 1e-3 m/s não muda nada no modelo completo
    const tol = if (cfg.method == method_model) @max(cfg.tol, 1e-3) else @max(cfg.tol, 1e-10);
    var it: usize = 0;
    while (hi - lo > tol and it < 100) : (it += 1) {
        const mid = 0.5 * (lo + hi);
        if ((excess(cfg, a, mid, &g) > 0) == flo) lo = mid else hi = mid;
    }
    return 0.5 * (lo + hi);
}

const Cross = struct { vmin: f64, vmax: f64, any: bool, Td_max: f64 };

/// procura na grade os cruzamentos e refina: V_min (− → +) e V_max (+ → −)
fn crossings(cfg: *const EnvCfg, a: *const Alt) Cross {
    var out = Cross{ .vmin = 0, .vmax = 0, .any = false, .Td_max = 0 };
    var g = [3]f64{ 0.1, -0.05, 0.5 };
    // de cima para baixo: o chute da trimagem vem do ponto anterior
    var V = cfg.V_hi;
    var f_prev = excess(cfg, a, V, &g);
    var have_max = false;
    var first_pos_low: f64 = -1;
    out.Td_max = a.thrust(V);
    if (f_prev > 0) {
        out.vmax = cfg.V_hi; // ainda sobra tração no fim da faixa
        have_max = true;
    }
    while (V - cfg.dV >= cfg.V_lo - 1e-12) {
        const Vn = V - cfg.dV;
        const f = excess(cfg, a, Vn, &g);
        out.Td_max = @max(out.Td_max, a.thrust(Vn));
        if (f > 0 and f_prev <= 0 and !have_max) {
            out.vmax = bisect(cfg, a, Vn, V);
            have_max = true;
        }
        if (f <= 0 and f_prev > 0 and have_max) {
            out.vmin = bisect(cfg, a, Vn, V);
            out.any = true;
            return out;
        }
        if (f > 0) first_pos_low = Vn;
        f_prev = f;
        V = Vn;
    }
    if (have_max and first_pos_low > 0) { // sobra tração até o começo da faixa
        out.vmin = cfg.V_lo;
        out.any = true;
    }
    return out;
}

fn altitude(p: *const T.Params, cfg: *const EnvCfg, h: f64, W: f64, CLmax_ac: f64) Alt {
    var a = Alt{ .p = p.*, .W = W, .rho = density(cfg, h), .raw = cfg.method == method_sheet and cfg.faithful != 0 };
    a.p.env.rho = a.rho;
    if (cfg.method == method_model) a.Vstall = @sqrt(2.0 * W / (a.rho * p.Sref * CLmax_ac));
    if (cfg.method == method_model and cfg.below_stall != 0) {
        a.below = true;
        a.plin = noStall(&a.p);
    }
    return a;
}

fn row(p: *const T.Params, cfg: *const EnvCfg, h: f64, W: f64, CLmax_ac: f64, alt: *Alt) EnvRow {
    alt.* = altitude(p, cfg, h, W, CLmax_ac);
    const a = alt;
    var r = EnvRow{ .h = h, .rho = a.rho };
    const c = crossings(cfg, a);
    r.Td_max = c.Td_max;
    r.ok = if (c.any) 1 else 0;
    r.Vmin = c.vmin;
    r.Vmax = c.vmax;
    if (cfg.method == method_sheet) {
        r.Ve = @sqrt(2.0 * W / (a.rho * (cfg.Sw * cfg.CLmax_w + cfg.Sh * cfg.CLmax_h)));
        const alphah = cfg.alpha_cruise * (1.0 - cfg.depsda) - cfg.eps0 + cfg.ih;
        const CLw = cfg.CL0_w + cfg.CLa_w * (cfg.iw + cfg.alpha_cruise);
        const CLh = -cfg.CL0_h + cfg.CLa_h * alphah;
        const Td_end = a.thrust(cfg.V_hi);
        r.Vcru = @sqrt(@abs(2.0 * (W - Td_end * fm.sin(cfg.alpha_cruise)) / (a.rho * (cfg.Sw * CLw + cfg.Sh * CLh))));
    } else {
        r.Ve = a.Vstall;
        r.Vcru = if (c.any) cruiseSpeed(cfg, a, c.vmin, c.vmax) else std.math.nan(f64);
    }
    r.Vman = r.Ve * @sqrt(cfg.n_load);
    return r;
}

/// modelo completo: V (dentro do envelope) em que o α de equilíbrio é o ângulo de cruzeiro
fn cruiseSpeed(cfg: *const EnvCfg, a: *const Alt, Vlo: f64, Vhi: f64) f64 {
    const tc = trim.Ctx.init(&a.p, &no_flags);
    const Fn = struct {
        fn da(t: trim.Ctx, V: f64, ac: f64) ?f64 {
            var g = [3]f64{ 0.1, -0.05, 0.5 };
            const tp = trim.solve(t, T.trim_level, V, 1.0, &g);
            return if (tp.ok != 0) tp.alpha - ac else null;
        }
    };
    var lo = Vlo + 1e-3;
    var hi = Vhi - 1e-3;
    // com `below`, o V_min pode estar abaixo do estol, onde a trimagem normal não existe: a busca começa no
    // primeiro V (a partir do V_e) em que ela converge
    if (a.below and lo < a.Vstall) {
        lo = a.Vstall;
        while (lo < hi and Fn.da(tc, lo, cfg.alpha_cruise) == null) lo += 0.05;
    }
    const alo = Fn.da(tc, lo, cfg.alpha_cruise) orelse return std.math.nan(f64);
    const ahi = Fn.da(tc, hi, cfg.alpha_cruise) orelse return std.math.nan(f64);
    if ((alo > 0) == (ahi > 0)) return std.math.nan(f64); // ângulo de cruzeiro fora do envelope
    var it: usize = 0;
    while (hi - lo > 1e-3 and it < 60) : (it += 1) {
        const mid = 0.5 * (lo + hi);
        const d = Fn.da(tc, mid, cfg.alpha_cruise) orelse return std.math.nan(f64);
        if ((d > 0) == (alo > 0)) lo = mid else hi = mid;
    }
    return 0.5 * (lo + hi);
}

/// C_L máximo da aeronave inteira (polar estática, profundor neutro)
fn aircraftCLmax(p: *const T.Params, rcg: vec.V3) f64 {
    var best: f64 = 0;
    var al: f64 = 0;
    while (al < 0.6) : (al += 0.002) best = @max(best, aero.coeffs(p, 15.0, al, 0, rcg, vec.zero).CL);
    return best;
}

/// linhas por altitude; devolve quantas e o teto absoluto (refinado por bisseção em h)
pub fn compute(p: *const T.Params, cfg: *const EnvCfg, rows: []EnvRow, ceiling: *f64) usize {
    const tc = trim.Ctx.init(p, &no_flags);
    const W = tc.m * L.g0;
    const CLmax_ac = aircraftCLmax(p, tc.rcg);
    var alt: Alt = undefined;
    var k: usize = 0;
    var h: f64 = 0;
    ceiling.* = 0;
    while (k < rows.len and h <= cfg.h_max) : (h += cfg.h_step) {
        const r = row(p, cfg, h, W, CLmax_ac, &alt);
        if (r.ok == 0 or r.Vmax - r.Vmin < cfg.tol) {
            // teto entre h − h_step e h
            var lo = @max(h - cfg.h_step, 0.0);
            var hi = h;
            if (k == 0) return 0;
            var it: usize = 0;
            while (hi - lo > 0.5 and it < 60) : (it += 1) {
                const mid = 0.5 * (lo + hi);
                alt = altitude(p, cfg, mid, W, CLmax_ac);
                const c = crossings(cfg, &alt);
                if (c.any and c.vmax - c.vmin >= cfg.tol) lo = mid else hi = mid;
            }
            ceiling.* = lo;
            return k;
        }
        rows[k] = r;
        k += 1;
        ceiling.* = h;
    }
    return k;
}

/// curvas T_d(V) e T_r(V) numa altitude (para os gráficos de potência)
pub fn curve(p: *const T.Params, cfg: *const EnvCfg, h: f64, V: []f64, Td: []f64, Tr: []f64) usize {
    const tc = trim.Ctx.init(p, &no_flags);
    const alt = altitude(p, cfg, h, tc.m * L.g0, aircraftCLmax(p, tc.rcg));
    const n = @min(V.len, @min(Td.len, Tr.len));
    var g = [3]f64{ 0.1, -0.05, 0.5 };
    var i: usize = n;
    while (i > 0) { // de cima para baixo (chute da trimagem)
        i -= 1;
        const v = cfg.V_lo + (cfg.V_hi - cfg.V_lo) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(n, 2) - 1));
        V[i] = v;
        Td[i] = alt.thrust(v);
        if (cfg.method == method_sheet) {
            Tr[i] = sheetDrag(cfg, &alt, v, Td[i]);
        } else {
            // tração requerida = tração no equilíbrio nivelado
            var tp = trim.solve(trim.Ctx.init(&alt.p, &no_flags), T.trim_level, v, 1.0, &g);
            if (alt.below and (v < 0.98 * alt.Vstall or tp.ok == 0 or tp.ratioCL > 1.0)) {
                if (tp.ok == 0) g = .{ 0.1, -0.05, 0.5 };
                tp = trim.solve(trim.Ctx.init(&alt.plin, &no_flags), T.trim_level, v, 1.0, &g);
            }
            Tr[i] = if (tp.ok != 0) tp.T else std.math.nan(f64);
            if (tp.ok == 0) g = .{ 0.1, -0.05, 0.5 };
        }
    }
    return n;
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
    var p = T.Params{ .m_dry = 8.0, .Sref = 0.6 };
    p.n_prop = 1;
    p.prop[0] = .{ .model = T.prop_poly, .poly_x = T.pvar_V, .poly_gain = 1, .poly_rho_exp = 1 };
    p.prop[0].poly[0] = 25; // T(V) = 25 − 0,04 V²
    p.prop[0].poly[3] = -0.04;
    prop.init(&p);
    const cfg = EnvCfg{ .Sw = 0.6, .CLmax_w = 1.4, .K = 0.06, .cdpw_c2 = 0.03, .cdph_c2 = 0.01, .faithful = 0, .h_step = 250, .dV = 0.1 };
    var rows: [200]EnvRow = undefined;
    var ceil: f64 = 0;
    const n = compute(&p, &cfg, &rows, &ceil);
    try testing.expect(n > 2);
    try testing.expect(ceil > 0 and ceil < cfg.h_max);
    for (rows[0..n]) |r| try testing.expect(r.Vmin < r.Vmax);
    try testing.expect(rows[n - 1].rho < rows[0].rho);
    try testing.expect(rows[n - 1].Vmax - rows[n - 1].Vmin < rows[0].Vmax - rows[0].Vmin);
}

test "sem estol (below_stall): a cópia mantém o C_L na reta depois do estol do original" {
    var p = T.Params{ .m_dry = 8.0, .Sref = 0.6 };
    p.n_surf = 1;
    p.surf[0].CL0 = 0.3;
    p.surf[0].CLa = 5.0;
    p.surf[0].a0 = 0.25; // estol do original em ~14°
    const q = noStall(&p);
    try testing.expectEqual(@as(f64, 0.25), p.surf[0].a0); // o original não muda
    try testing.expectEqual(@as(f64, 10.0), q.surf[0].a0);
    const al: f64 = 0.4; // depois do estol do original
    const cl = aero.sigmaStall(al, q.surf[0].a0, 50.0);
    try testing.expect(cl < 1e-6); // a mistura com a placa plana some: só a reta
    try testing.expect(aero.sigmaStall(al, p.surf[0].a0, 50.0) > 0.99);
}
