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
const fmath = @import("../math/fmath.zig");
const limits = @import("../limits.zig");

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

/// densidade ISA na altitude da configuração (kg/m³)
pub fn density(cfg: *const SimpleCfg) f64 {
    return cfg.rho0 * std.math.pow(f64, 1.0 + cfg.lapse * cfg.h / cfg.T0, -limits.g0 / (cfg.lapse * cfg.Rgas) - 1.0);
}

/// tração disponível em V: interpola a tabela T(V) e corrige por (ρ/ρ0)^m
fn thrust(cfg: *const SimpleCfg, airspeed: f64, sigma: f64) f64 {
    const point_count: usize = @intCast(@max(cfg.n_thr, 0));
    if (point_count == 0) return 0;
    var thrust_value: f64 = cfg.thr_T[point_count - 1];
    if (airspeed <= cfg.thr_V[0]) {
        thrust_value = cfg.thr_T[0];
    } else {
        for (1..point_count) |i| {
            if (airspeed <= cfg.thr_V[i]) {
                const fraction = (airspeed - cfg.thr_V[i - 1]) / (cfg.thr_V[i] - cfg.thr_V[i - 1]);
                thrust_value = cfg.thr_T[i - 1] + fraction * (cfg.thr_T[i] - cfg.thr_T[i - 1]);
                break;
            }
        }
    }
    return @max(thrust_value, 0.0) * std.math.pow(f64, sigma, cfg.rho_exp);
}

/// preenche as linhas (uma por V) e o resumo; devolve quantas linhas
pub fn compute(cfg: *const SimpleCfg, rows: []SimpleRow, summary: *SimpleSummary) usize {
    const gravity = limits.g0;
    const rho = density(cfg);
    const sigma = rho / cfg.rho0;
    const WS = cfg.W / cfg.S;
    summary.* = .{};
    summary.rho = rho;
    summary.WS = WS;
    summary.Vs = @sqrt(2.0 * WS / (rho * cfg.CLmax));
    summary.Vman = summary.Vs * @sqrt(@max(cfg.n_load, 1.0));
    summary.glide_min = 1e9;
    summary.sink_min = 1e9;
    const sphi = fmath.sin(cfg.phi_T);
    var row_count: usize = 0;
    var airspeed = cfg.V_lo;
    var prev_ex: f64 = std.math.nan(f64);
    var TWmax: f64 = 0;
    const bank_count: usize = @intCast(@max(@min(cfg.n_bank, max_bank), 0));
    while (airspeed <= cfg.V_hi + 1e-9 and row_count < rows.len) : (airspeed += cfg.dV) {
        var row = std.mem.zeroes(SimpleRow);
        row.V = airspeed;
        const dyn_pressure = 0.5 * rho * airspeed * airspeed;
        const Td = thrust(cfg, airspeed, sigma);
        TWmax = @max(TWmax, Td / cfg.W);
        const CL = 2.0 * (cfg.W - Td * sphi) / (rho * cfg.S * airspeed * airspeed);
        const CD = cfg.CD0 + cfg.K * CL * CL;
        row.CL = CL;
        row.CD = CD;
        row.ok = if (CL <= cfg.CLmax and CL > 0) 1 else 0;
        row.Td = Td;
        row.Tr = cfg.W * CD / CL;
        row.Pd = Td * airspeed;
        row.Pr = row.Tr * airspeed;
        row.RC = (row.Pd - row.Pr) / cfg.W;
        row.gam = fmath.asin(fmath.lim(row.RC / airspeed, -1.0, 1.0));
        row.E = CL / CD;
        row.gam_glide = fmath.atan(1.0 / row.E);
        row.V_glide = @sqrt(2.0 * cfg.W * fmath.cos(row.gam_glide) / (rho * cfg.S * CL));
        row.sink = row.V_glide * fmath.sin(row.gam_glide);
        // curva: limite de estol e de tração
        row.n_stall = dyn_pressure * cfg.S * cfg.CLmax / cfg.W;
        const arg = dyn_pressure / (cfg.K * WS) * (Td / cfg.W - dyn_pressure * cfg.CD0 / WS);
        row.n_sust = if (arg > 0) @sqrt(arg) else 0;
        row.R_stall = if (row.n_stall > 1) airspeed * airspeed / (gravity * @sqrt(row.n_stall * row.n_stall - 1)) else std.math.inf(f64);
        row.R_sust = if (row.n_sust > 1) airspeed * airspeed / (gravity * @sqrt(row.n_sust * row.n_sust - 1)) else std.math.inf(f64);
        for (0..bank_count) |k| row.R_bank[k] = airspeed * airspeed / (gravity * fmath.tan(cfg.bank[k]));
        // bateria (Peukert) na potência requerida
        const Pel = row.Pr / cfg.bat_eta;
        row.t_bat = std.math.pow(f64, cfg.bat_Rt, 1.0 - cfg.bat_n) * std.math.pow(f64, cfg.bat_V * cfg.bat_C / Pel, cfg.bat_n);
        row.range_bat = row.t_bat * 3600.0 * airspeed;
        // V_min e V_max onde P_d = P_r em toda a faixa (como na planilha: sem cortar no C_Lmax)
        if (CL > 0) {
            const ex = row.Pd - row.Pr;
            if (ex >= 0) summary.ceiling_ok = 1;
            if (!std.math.isNan(prev_ex)) {
                if (prev_ex < 0 and ex >= 0 and summary.Vmin == 0) summary.Vmin = airspeed;
                if (prev_ex >= 0 and ex < 0) summary.Vmax = airspeed;
            } else if (ex >= 0) summary.Vmin = airspeed;
            prev_ex = ex;
        }
        if (row.ok > 0) {
            if (row.RC > summary.RCmax) {
                summary.RCmax = row.RC;
                summary.V_RCmax = airspeed;
            }
            if (row.gam > summary.gmax) {
                summary.gmax = row.gam;
                summary.V_gmax = airspeed;
            }
            if (row.E > summary.Emax) {
                summary.Emax = row.E;
                summary.V_Emax = airspeed;
            }
            if (row.gam_glide < summary.glide_min) {
                summary.glide_min = row.gam_glide;
                summary.V_glide_min = row.V_glide;
            }
            if (row.sink < summary.sink_min) {
                summary.sink_min = row.sink;
                summary.V_sink_min = row.V_glide;
            }
            if (row.t_bat > summary.t_max) {
                summary.t_max = row.t_bat;
                summary.V_tmax = airspeed;
            }
            if (row.range_bat > summary.range_max) {
                summary.range_max = row.range_bat;
                summary.V_range_max = airspeed;
            }
        }
        rows[row_count] = row;
        row_count += 1;
    }
    if (summary.ceiling_ok > 0 and summary.Vmax == 0) summary.Vmax = cfg.V_hi; // ainda sobra potência no fim da faixa
    summary.V_LDmax = @sqrt(2.0 * WS / (rho * @sqrt(cfg.CD0 / cfg.K)));
    // raio mínimo (curva sustentada no T/W máximo), como na planilha
    summary.TW_max = TWmax;
    const discriminant = 1.0 - 4.0 * cfg.K * cfg.CD0 / (TWmax * TWmax);
    if (TWmax > 0 and discriminant > 0) {
        summary.V_Rmin = @sqrt(4.0 * cfg.K * WS / (TWmax * rho));
        summary.n_Rmin = @sqrt(2.0 - 4.0 * cfg.K * cfg.CD0 / (TWmax * TWmax));
        summary.R_min = 4.0 * cfg.K * WS / (rho * gravity * TWmax * @sqrt(discriminant));
        summary.phi_Rmin = fmath.acos(1.0 / summary.n_Rmin);
    }
    // autonomia máxima (fórmula fechada de Traub)
    const den = (2.0 / @sqrt(rho * cfg.S)) * std.math.pow(f64, cfg.CD0, 0.25) *
        std.math.pow(f64, 2.0 * cfg.W * @sqrt(cfg.K / 3.0), 1.5);
    summary.t_max_formula = std.math.pow(f64, cfg.bat_Rt, 1.0 - cfg.bat_n) *
        std.math.pow(f64, cfg.bat_eta * cfg.bat_V * cfg.bat_C / den, cfg.bat_n);
    return row_count;
}

test "densidade ISA a 900 m (planilha: 1,129)" {
    var cfg = SimpleCfg{};
    cfg.h = 900;
    cfg.T0 = 308.15;
    try std.testing.expectApproxEqAbs(@as(f64, 1.12900), density(&cfg), 1e-4);
}

test "raio mínimo e potência como na planilha" {
    var cfg = SimpleCfg{ .W = 7.32 * 9.81, .S = 0.44, .CD0 = 0.0253526912130295, .K = 0.3183102044939952, .CLmax = 2.2216 };
    cfg.n_thr = 2;
    cfg.thr_V[0] = 0;
    cfg.thr_T[0] = 9.81 * 5.11;
    cfg.thr_V[1] = 40;
    cfg.thr_T[1] = 9.81 * 5.11;
    var rows: [100]SimpleRow = undefined;
    var summary: SimpleSummary = undefined;
    const row_count = compute(&cfg, &rows, &summary);
    try std.testing.expect(row_count > 10);
    // R_min = 4 K (W/S) / (ρ g (T/W) √(1 − 4 K C_D0/(T/W)²))
    const TW = 5.11 / 7.32;
    const WS = 7.32 * 9.81 / 0.44;
    const expected_radius = 4 * cfg.K * WS / (1.225 * 9.80665 * TW * @sqrt(1 - 4 * cfg.K * cfg.CD0 / (TW * TW)));
    try std.testing.expectApproxEqRel(expected_radius, summary.R_min, 1e-9);
}
