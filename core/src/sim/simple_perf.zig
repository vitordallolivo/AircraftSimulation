//! Desempenho por cálculo simples (sem simulação no tempo), como na "planilha suprema":
//! polar parabólica C_D = C_D0 + K C_L², tração disponível por tabela T(V) ao nível do mar
//! corrigida por (ρ/ρ0)^m, densidade ISA ρ = ρ0 (1 + λh/T0)^(−g/(λR) − 1).
//!
//! Para cada V numa altitude:
//!   potências   C_L = 2 (W − T sen φ_T)/(ρ S V²),  T_r = W C_D/C_L,  P_r = T_r V,  P_d = T_d V
//!   subida      RC = (P_d − P_r)/W,  γ = asen(RC/V)
//!   descida     planeio no C_L do ponto: E = C_L/C_D, γ = atan(1/E), V = √(2W cos γ/(ρ S C_L)),
//!               razão de descida = V sen γ
//!   curva       R = V²/(g tan φ) para cada inclinação φ; limites: estol n = (V/V_e)² C_L/C_Lmax e
//!               tração (curva sustentada) n = √(q/(K W/S) (T/W − q C_D0/(W/S)))
//!   bateria     Peukert (Traub, J. Aircraft 48(2), 2011, doi 10.2514/1.C031027):
//!               t = R_t^(1−n) (η V_bat C / P)^n  (h), alcance = t V
//! Resumo: V_e, V*, V_min/V_max (P_d = P_r), RC máx., γ máx., E máx. e menor ângulo de planeio,
//! menor razão de descida, raio mínimo (fórmula fechada da planilha), autonomia e alcance máximos.
const std = @import("std");
const fm = @import("../math/fmath.zig");
const L = @import("../limits.zig");

pub const max_pts = 128;
pub const max_bank = 8;

pub const SimpleCfg = extern struct {
    W: f64 = 100, // peso (N)
    S: f64 = 1, // área de referência (m²)
    CD0: f64 = 0.03,
    K: f64 = 0.06,
    CLmax: f64 = 1.4,
    rho0: f64 = 1.225,
    h: f64 = 0, // altitude (m)
    T0: f64 = 288.15, // temperatura no nível de referência (K)
    lapse: f64 = -0.0065, // λ (K/m)
    Rgas: f64 = 287.053,
    phi_T: f64 = 0, // inclinação do motor (rad): parte da tração sustenta
    rho_exp: f64 = 1, // T ∝ (ρ/ρ0)^m
    V_lo: f64 = 1,
    V_hi: f64 = 30,
    dV: f64 = 0.5,
    n_load: f64 = 2, // V* = V_e √n
    bat_Rt: f64 = 1, // tempo de descarga nominal (h)
    bat_C: f64 = 5, // capacidade (Ah)
    bat_n: f64 = 1.05, // expoente de Peukert
    bat_V: f64 = 22.2, // tensão do pacote (V)
    bat_eta: f64 = 0.6, // rendimento total (motor, ESC, hélice)
    n_thr: i32 = 0,
    n_bank: i32 = 0,
    thr_V: [max_pts]f64 = [_]f64{0} ** max_pts,
    thr_T: [max_pts]f64 = [_]f64{0} ** max_pts,
    bank: [max_bank]f64 = [_]f64{0} ** max_bank, // inclinações (rad) para R = V²/(g tan φ)
};

pub const SimpleRow = extern struct {
    V: f64,
    CL: f64,
    CD: f64,
    ok: f64, // 1: C_L ≤ C_Lmax (voo nivelado possível)
    Td: f64,
    Tr: f64,
    Pd: f64,
    Pr: f64,
    RC: f64,
    gam: f64,
    E: f64,
    gam_glide: f64,
    V_glide: f64,
    sink: f64,
    n_stall: f64,
    n_sust: f64,
    R_stall: f64,
    R_sust: f64,
    R_bank: [max_bank]f64,
    t_bat: f64, // autonomia na potência requerida (h)
    range_bat: f64, // alcance (m)
};

pub const SimpleSummary = extern struct {
    rho: f64 = 0,
    Vs: f64 = 0,
    Vman: f64 = 0,
    Vmin: f64 = 0,
    Vmax: f64 = 0,
    RCmax: f64 = 0,
    V_RCmax: f64 = 0,
    gmax: f64 = 0,
    V_gmax: f64 = 0,
    Emax: f64 = 0,
    V_Emax: f64 = 0,
    glide_min: f64 = 0,
    V_glide_min: f64 = 0,
    sink_min: f64 = 0,
    V_sink_min: f64 = 0,
    TW_max: f64 = 0,
    WS: f64 = 0,
    V_Rmin: f64 = 0,
    R_min: f64 = 0,
    n_Rmin: f64 = 0,
    phi_Rmin: f64 = 0,
    t_max: f64 = 0,
    V_tmax: f64 = 0,
    range_max: f64 = 0,
    V_range_max: f64 = 0,
    t_max_formula: f64 = 0, // autonomia máxima pela fórmula fechada de Traub (h)
    ceiling_ok: f64 = 0, // 1: há V com P_d ≥ P_r
    V_LDmax: f64 = 0, // V de L/D máximo (cruzeiro de maior alcance): C_L = √(C_D0/K)
};

pub fn density(c: *const SimpleCfg) f64 {
    return c.rho0 * std.math.pow(f64, 1.0 + c.lapse * c.h / c.T0, -L.g0 / (c.lapse * c.Rgas) - 1.0);
}

fn thrust(c: *const SimpleCfg, V: f64, sigma: f64) f64 {
    const n: usize = @intCast(@max(c.n_thr, 0));
    if (n == 0) return 0;
    var T: f64 = c.thr_T[n - 1];
    if (V <= c.thr_V[0]) {
        T = c.thr_T[0];
    } else {
        for (1..n) |i| {
            if (V <= c.thr_V[i]) {
                const f = (V - c.thr_V[i - 1]) / (c.thr_V[i] - c.thr_V[i - 1]);
                T = c.thr_T[i - 1] + f * (c.thr_T[i] - c.thr_T[i - 1]);
                break;
            }
        }
    }
    return @max(T, 0.0) * std.math.pow(f64, sigma, c.rho_exp);
}

/// preenche as linhas (uma por V) e o resumo; devolve quantas linhas
pub fn compute(c: *const SimpleCfg, rows: []SimpleRow, sum: *SimpleSummary) usize {
    const g = L.g0;
    const rho = density(c);
    const sigma = rho / c.rho0;
    const WS = c.W / c.S;
    sum.* = .{};
    sum.rho = rho;
    sum.WS = WS;
    sum.Vs = @sqrt(2.0 * WS / (rho * c.CLmax));
    sum.Vman = sum.Vs * @sqrt(@max(c.n_load, 1.0));
    sum.glide_min = 1e9;
    sum.sink_min = 1e9;
    const sphi = fm.sin(c.phi_T);
    var n: usize = 0;
    var V = c.V_lo;
    var prev_ex: f64 = std.math.nan(f64);
    var TWmax: f64 = 0;
    const nb: usize = @intCast(@max(@min(c.n_bank, max_bank), 0));
    while (V <= c.V_hi + 1e-9 and n < rows.len) : (V += c.dV) {
        var r = std.mem.zeroes(SimpleRow);
        r.V = V;
        const q = 0.5 * rho * V * V;
        const Td = thrust(c, V, sigma);
        TWmax = @max(TWmax, Td / c.W);
        const CL = 2.0 * (c.W - Td * sphi) / (rho * c.S * V * V);
        const CD = c.CD0 + c.K * CL * CL;
        r.CL = CL;
        r.CD = CD;
        r.ok = if (CL <= c.CLmax and CL > 0) 1 else 0;
        r.Td = Td;
        r.Tr = c.W * CD / CL;
        r.Pd = Td * V;
        r.Pr = r.Tr * V;
        r.RC = (r.Pd - r.Pr) / c.W;
        r.gam = fm.asin(fm.lim(r.RC / V, -1.0, 1.0));
        r.E = CL / CD;
        r.gam_glide = fm.atan(1.0 / r.E);
        r.V_glide = @sqrt(2.0 * c.W * fm.cos(r.gam_glide) / (rho * c.S * CL));
        r.sink = r.V_glide * fm.sin(r.gam_glide);
        // curva: limite de estol e de tração
        r.n_stall = q * c.S * c.CLmax / c.W;
        const arg = q / (c.K * WS) * (Td / c.W - q * c.CD0 / WS);
        r.n_sust = if (arg > 0) @sqrt(arg) else 0;
        r.R_stall = if (r.n_stall > 1) V * V / (g * @sqrt(r.n_stall * r.n_stall - 1)) else std.math.inf(f64);
        r.R_sust = if (r.n_sust > 1) V * V / (g * @sqrt(r.n_sust * r.n_sust - 1)) else std.math.inf(f64);
        for (0..nb) |k| r.R_bank[k] = V * V / (g * fm.tan(c.bank[k]));
        // bateria (Peukert) na potência requerida
        const Pel = r.Pr / c.bat_eta;
        r.t_bat = std.math.pow(f64, c.bat_Rt, 1.0 - c.bat_n) * std.math.pow(f64, c.bat_V * c.bat_C / Pel, c.bat_n);
        r.range_bat = r.t_bat * 3600.0 * V;
        // V_min e V_max onde P_d = P_r em toda a faixa (como na planilha: sem cortar no C_Lmax)
        if (CL > 0) {
            const ex = r.Pd - r.Pr;
            if (ex >= 0) sum.ceiling_ok = 1;
            if (!std.math.isNan(prev_ex)) {
                if (prev_ex < 0 and ex >= 0 and sum.Vmin == 0) sum.Vmin = V;
                if (prev_ex >= 0 and ex < 0) sum.Vmax = V;
            } else if (ex >= 0) sum.Vmin = V;
            prev_ex = ex;
        }
        if (r.ok > 0) {
            if (r.RC > sum.RCmax) {
                sum.RCmax = r.RC;
                sum.V_RCmax = V;
            }
            if (r.gam > sum.gmax) {
                sum.gmax = r.gam;
                sum.V_gmax = V;
            }
            if (r.E > sum.Emax) {
                sum.Emax = r.E;
                sum.V_Emax = V;
            }
            if (r.gam_glide < sum.glide_min) {
                sum.glide_min = r.gam_glide;
                sum.V_glide_min = r.V_glide;
            }
            if (r.sink < sum.sink_min) {
                sum.sink_min = r.sink;
                sum.V_sink_min = r.V_glide;
            }
            if (r.t_bat > sum.t_max) {
                sum.t_max = r.t_bat;
                sum.V_tmax = V;
            }
            if (r.range_bat > sum.range_max) {
                sum.range_max = r.range_bat;
                sum.V_range_max = V;
            }
        }
        rows[n] = r;
        n += 1;
    }
    if (sum.ceiling_ok > 0 and sum.Vmax == 0) sum.Vmax = c.V_hi; // ainda sobra potência no fim da faixa
    sum.V_LDmax = @sqrt(2.0 * WS / (rho * @sqrt(c.CD0 / c.K)));
    // raio mínimo (curva sustentada no T/W máximo), como na planilha
    sum.TW_max = TWmax;
    const d = 1.0 - 4.0 * c.K * c.CD0 / (TWmax * TWmax);
    if (TWmax > 0 and d > 0) {
        sum.V_Rmin = @sqrt(4.0 * c.K * WS / (TWmax * rho));
        sum.n_Rmin = @sqrt(2.0 - 4.0 * c.K * c.CD0 / (TWmax * TWmax));
        sum.R_min = 4.0 * c.K * WS / (rho * g * TWmax * @sqrt(d));
        sum.phi_Rmin = fm.acos(1.0 / sum.n_Rmin);
    }
    // autonomia máxima (fórmula fechada de Traub)
    const den = (2.0 / @sqrt(rho * c.S)) * std.math.pow(f64, c.CD0, 0.25) *
        std.math.pow(f64, 2.0 * c.W * @sqrt(c.K / 3.0), 1.5);
    sum.t_max_formula = std.math.pow(f64, c.bat_Rt, 1.0 - c.bat_n) *
        std.math.pow(f64, c.bat_eta * c.bat_V * c.bat_C / den, c.bat_n);
    return n;
}

test "densidade ISA a 900 m (planilha: 1,129)" {
    var c = SimpleCfg{};
    c.h = 900;
    c.T0 = 308.15;
    try std.testing.expectApproxEqAbs(@as(f64, 1.12900), density(&c), 1e-4);
}

test "raio mínimo e potência como na planilha" {
    var c = SimpleCfg{ .W = 7.32 * 9.81, .S = 0.44, .CD0 = 0.0253526912130295, .K = 0.3183102044939952, .CLmax = 2.2216 };
    c.n_thr = 2;
    c.thr_V[0] = 0;
    c.thr_T[0] = 9.81 * 5.11;
    c.thr_V[1] = 40;
    c.thr_T[1] = 9.81 * 5.11;
    var rows: [100]SimpleRow = undefined;
    var s: SimpleSummary = undefined;
    const n = compute(&c, &rows, &s);
    try std.testing.expect(n > 10);
    // R_min = 4 K (W/S) / (ρ g (T/W) √(1 − 4 K C_D0/(T/W)²))
    const TW = 5.11 / 7.32;
    const WS = 7.32 * 9.81 / 0.44;
    const R = 4 * c.K * WS / (1.225 * 9.80665 * TW * @sqrt(1 - 4 * c.K * c.CD0 / (TW * TW)));
    try std.testing.expectApproxEqRel(R, s.R_min, 1e-9);
}
