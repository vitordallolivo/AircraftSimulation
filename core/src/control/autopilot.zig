//! Piloto automático.
//!
//! Decolagem (Riboldi et al., 2022): acelerador cheio, profundor δe0 até VR (ou sR) e
//!   δe1 depois (com a taxa do servo); no chão, leme e roda direcionável seguem a pista.
//! Depois de h_t: altura → fator de carga vertical → α pedido (com limite) → profundor;
//!   velocidade pelo acelerador com o erro de altura somado (energia total);
//!   lateral pelo curso (inclinação) e leme zerando β.
//! Pouso: abaixo de hflare, arredondamento exponencial; no chão, freio.
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const state = @import("../sim/state.zig");
const guidance = @import("guidance.zig");
const fmath = @import("../math/fmath.zig");
const terrain = @import("../physics/terrain.zig");

pub const Cmd = struct {
    thr: f64 = 0,
    de: f64 = 0,
    da: f64 = 0,
    dr: f64 = 0,
    dw: f64 = 0,
    thc: f64 = 0,
    alc: f64 = 0,
    phic: f64 = 0,
    href: f64 = 0,
    hdref: f64 = 0,
    alim: bool = false,
};

pub const Input = struct {
    Va: f64,
    Vg: f64,
    al: f64,
    be: f64,
    chi: f64,
    hdot: f64,
    qb: f64,
    m: f64,
    on_ground: bool,
};

fn takeoffElevator(c: state.Ctx, t: f64) f64 {
    const to = &c.p.takeoff;
    if (c.tR < 0.0 or t < c.tR) return to.de0;
    var d = to.de1 - to.de0;
    const dmax = to.rate_de * (t - c.tR);
    if (@abs(d) > dmax) d = fmath.sgn(d) * dmax;
    return to.de0 + d;
}

/// q de uma curva nivelada com inclinação φ
pub fn qTurn(phi: f64, Va: f64) f64 {
    const sph = fmath.sin(phi);
    const cph = fmath.cos(fmath.lim(phi, -75.0 * std.math.rad_per_deg, 75.0 * std.math.rad_per_deg));
    return limits.g0 / @max(Va, 3.0) * sph * sph / cph;
}

pub fn commands(c: state.Ctx, t: f64, x: []const f64, in: Input, g: *const guidance.Guide, dx: []f64) Cmd {
    const p = c.p;
    const a = &p.ap;
    const f = c.f;
    var cmd = Cmd{};
    const h = -x[state.D];
    const Vgl = @max(in.Vg, 3.0);
    const noar = !in.on_ground and f.brakes == 0 and f.landed == 0;
    const autop = f.autop != 0;

    // altura de referência: segue o segmento com taxa limitada
    var rate = fmath.lim(a.Khr * (g.hseg - x[state.HR]), -a.g_down * Vgl, a.g_up * Vgl);
    // prioridade da velocidade: abaixo de Vseg a subida pedida diminui
    if (rate > 0.0) rate *= fmath.lim(1.0 - a.Kvs * (g.Vseg - in.Va), 0.0, 1.0);
    dx[state.HR] = if (autop) rate else 0.0;
    cmd.href = if (autop) x[state.HR] else g.hseg;
    cmd.hdref = if (autop) rate else 0.0;
    const eh = cmd.href - h;
    const ehd = cmd.hdref - in.hdot;

    // ---------------- longitudinal ----------------
    const cph = fmath.cos(fmath.lim(x[state.PHI], -75.0 * std.math.rad_per_deg, 75.0 * std.math.rad_per_deg));
    const qref = qTurn(x[state.PHI], in.Va);
    cmd.alc = in.al;
    if (!autop) {
        cmd.thr = if (f.brakes != 0) 0.0 else fmath.lim(p.takeoff.rate_thr * t, 0.0, 1.0);
        cmd.de = takeoffElevator(c, t);
        if (p.takeoff.alpha_guard != 0 and c.tR >= 0.0 and t >= c.tR) {
            // proteção de α na decolagem: a mesma lei do voo (α e q) com α pedido = o do estol do avião
            // (alpha_guard_lim, runner.guardAlpha); só pica, nunca cabra mais que o comando de decolagem
            const alim = if (p.alpha_guard_lim > 0.0) p.alpha_guard_lim else a.alpha_max;
            const de_g = a.Kae * (in.al - alim) + a.Kqe * x[state.Q];
            if (de_g > cmd.de) {
                cmd.de = de_g;
                cmd.alim = true;
            }
        }
        cmd.thc = x[state.THE];
    } else if (f.landed != 0) {
        cmd.thc = 0.0;
        cmd.thr = 0.0;
        cmd.de = a.Kthe * x[state.THE] + a.Kqe * x[state.Q];
    } else {
        // h'' = g (n cos φ − cos γ)  =>  n cos φ = cos γ_ref + Kn_h e_h + Kn_hd e_ḣ + Kn_ih ∫e_h
        const gref = fmath.atan2(cmd.hdref, Vgl);
        var nv = fmath.cos(gref) + a.Kn_h * eh + a.Kn_hd * ehd + a.Kn_ih * x[state.IH];
        cmd.thr = fmath.lim(a.Dtrim + a.KV * (g.Vseg - in.Va) + a.KIV * x[state.IV] + a.KHT * eh, 0.0, 1.0);
        if (f.flare != 0) { // arredondamento exponencial: dh/dt = −h_rodas / τ
            const hw = h - terrain.height(p, x[state.N], x[state.E]) - c.h_rest;
            cmd.hdref = -fmath.lim(hw / a.tau_flare, 0.2, @max(-in.hdot, 0.2));
            nv = 1.0 + a.Kfn * (cmd.hdref - in.hdot);
            if (hw < 0.3) cmd.thr = 0.0;
        }
        nv = fmath.lim(nv, 0.0, 3.0);
        const CLc = if (in.qb > 5.0) nv / cph * in.m * limits.g0 / (in.qb * p.Sref) else a.CL0;
        const al_free = (CLc - a.CL0) / a.CLa;
        cmd.alc = fmath.lim(al_free, -6.0 * std.math.rad_per_deg, a.alpha_max); // proteção de α
        cmd.alim = al_free >= a.alpha_max;
        cmd.thc = x[state.THE] + (cmd.alc - in.al);
        cmd.de = a.Kae * (in.al - cmd.alc) + a.Kqe * (x[state.Q] - qref) + a.KIa * x[state.ITH];
    }
    cmd.de = fmath.sat(cmd.de, a.de_max);

    // ---------------- látero-direcional ----------------
    if (in.on_ground) {
        const psiref = g.chip - fmath.atan(a.Ky * g.ect + a.Ki * x[state.IE]);
        const uy = a.Kpsi * fmath.wrap(psiref - x[state.PSI]) - a.Kr * x[state.R];
        cmd.da = -a.Kphia * x[state.PHI] - a.Kpa * x[state.P];
        cmd.dr = -uy;
        cmd.dw = a.Kbeq * uy * p.steer_sign;
        cmd.phic = 0.0;
        dx[state.PHC] = -x[state.PHC] / a.tau_phi;
    } else {
        // inclinação máxima que a asa sustenta sem perder altura: 1/cos φ <= n_max(α_max)
        const CLlim = a.CL0 + a.CLa * a.alpha_max;
        const nmax = in.qb * p.Sref * CLlim / (in.m * limits.g0);
        var philim = if (nmax > 1.0) fmath.acos(1.0 / nmax) else 0.0;
        if (philim > a.phimax) philim = a.phimax;
        const phir = if (in.Vg > 3.0) fmath.sat(g.phiff + a.Kchi * fmath.wrap(g.chid - in.chi), philim) else 0.0;
        dx[state.PHC] = fmath.sat((phir - x[state.PHC]) / a.tau_phi, a.pmax_cmd);
        cmd.phic = x[state.PHC];
        cmd.da = a.Kphia * (cmd.phic - x[state.PHI]) - a.Kpa * x[state.P];
        cmd.dr = -a.Kbeta * in.be;
        cmd.dw = 0.0;
    }
    cmd.da = fmath.sat(cmd.da, a.da_max);
    cmd.dr = fmath.sat(cmd.dr, a.dr_max);
    cmd.dw = fmath.sat(cmd.dw, 20.0 * std.math.rad_per_deg);

    // ---------------- integradores ----------------
    const active = autop and noar and f.flare == 0;
    dx[state.IH] = if (active) fmath.sat(eh, 3.0) else 0.0;
    const thr_free = a.Dtrim + a.KV * (g.Vseg - in.Va) + a.KIV * x[state.IV] + a.KHT * eh;
    const saturated = (thr_free > 1.0 and g.Vseg > in.Va) or (thr_free < 0.0 and g.Vseg < in.Va);
    dx[state.IV] = if (active and !saturated) g.Vseg - in.Va else 0.0;
    dx[state.ITH] = if (active) fmath.sat(in.al - cmd.alc, 5.0 * std.math.rad_per_deg) else 0.0;
    dx[state.IE] = if (in.on_ground) g.ect else 0.0;
    return cmd;
}
