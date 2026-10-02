//! Piloto automático.
//!
//! Decolagem (Riboldi et al., 2022): acelerador cheio, profundor δe0 até VR (ou sR) e
//!   δe1 depois (com a taxa do servo); no chão, leme e roda direcionável seguem a pista.
//! Depois de h_t: altura → fator de carga vertical → α pedido (com limite) → profundor;
//!   velocidade pelo acelerador com o erro de altura somado (energia total);
//!   lateral pelo curso (inclinação) e leme zerando β.
//! Pouso: abaixo de hflare, arredondamento exponencial; no chão, freio.
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const S = @import("../sim/state.zig");
const G = @import("guidance.zig");
const fm = @import("../math/fmath.zig");

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

fn takeoffElevator(c: S.Ctx, t: f64) f64 {
    const to = &c.p.takeoff;
    if (c.tR < 0.0 or t < c.tR) return to.de0;
    var d = to.de1 - to.de0;
    const dmax = to.rate_de * (t - c.tR);
    if (@abs(d) > dmax) d = fm.sgn(d) * dmax;
    return to.de0 + d;
}

/// q de uma curva nivelada com inclinação φ
pub fn qTurn(phi: f64, Va: f64) f64 {
    const sph = fm.sin(phi);
    const cph = fm.cos(fm.lim(phi, -75.0 * std.math.rad_per_deg, 75.0 * std.math.rad_per_deg));
    return L.g0 / @max(Va, 3.0) * sph * sph / cph;
}

pub fn commands(c: S.Ctx, t: f64, x: []const f64, in: Input, g: *const G.Guide, dx: []f64) Cmd {
    const p = c.p;
    const a = &p.ap;
    const f = c.f;
    var cmd = Cmd{};
    const h = -x[S.D];
    const Vgl = @max(in.Vg, 3.0);
    const noar = !in.on_ground and f.brakes == 0 and f.landed == 0;
    const autop = f.autop != 0;

    // altura de referência: segue o segmento com taxa limitada
    var rate = fm.lim(a.Khr * (g.hseg - x[S.HR]), -a.g_down * Vgl, a.g_up * Vgl);
    // prioridade da velocidade: abaixo de Vseg a subida pedida diminui
    if (rate > 0.0) rate *= fm.lim(1.0 - a.Kvs * (g.Vseg - in.Va), 0.0, 1.0);
    dx[S.HR] = if (autop) rate else 0.0;
    cmd.href = if (autop) x[S.HR] else g.hseg;
    cmd.hdref = if (autop) rate else 0.0;
    const eh = cmd.href - h;
    const ehd = cmd.hdref - in.hdot;

    // ---------------- longitudinal ----------------
    const cph = fm.cos(fm.lim(x[S.PHI], -75.0 * std.math.rad_per_deg, 75.0 * std.math.rad_per_deg));
    const qref = qTurn(x[S.PHI], in.Va);
    cmd.alc = in.al;
    if (!autop) {
        cmd.thr = if (f.brakes != 0) 0.0 else fm.lim(p.takeoff.rate_thr * t, 0.0, 1.0);
        cmd.de = takeoffElevator(c, t);
        cmd.thc = x[S.THE];
    } else if (f.landed != 0) {
        cmd.thc = 0.0;
        cmd.thr = 0.0;
        cmd.de = a.Kthe * x[S.THE] + a.Kqe * x[S.Q];
    } else {
        // h'' = g (n cos φ − cos γ)  =>  n cos φ = cos γ_ref + Kn_h e_h + Kn_hd e_ḣ + Kn_ih ∫e_h
        const gref = fm.atan2(cmd.hdref, Vgl);
        var nv = fm.cos(gref) + a.Kn_h * eh + a.Kn_hd * ehd + a.Kn_ih * x[S.IH];
        cmd.thr = fm.lim(a.Dtrim + a.KV * (g.Vseg - in.Va) + a.KIV * x[S.IV] + a.KHT * eh, 0.0, 1.0);
        if (f.flare != 0) { // arredondamento exponencial: dh/dt = −h_rodas / τ
            const hw = h - c.h_ground;
            cmd.hdref = -fm.lim(hw / a.tau_flare, 0.2, @max(-in.hdot, 0.2));
            nv = 1.0 + a.Kfn * (cmd.hdref - in.hdot);
            if (hw < 0.3) cmd.thr = 0.0;
        }
        nv = fm.lim(nv, 0.0, 3.0);
        const CLc = if (in.qb > 5.0) nv / cph * in.m * L.g0 / (in.qb * p.Sref) else a.CL0;
        const al_free = (CLc - a.CL0) / a.CLa;
        cmd.alc = fm.lim(al_free, -6.0 * std.math.rad_per_deg, a.alpha_max); // proteção de α
        cmd.alim = al_free >= a.alpha_max;
        cmd.thc = x[S.THE] + (cmd.alc - in.al);
        cmd.de = a.Kae * (in.al - cmd.alc) + a.Kqe * (x[S.Q] - qref) + a.KIa * x[S.ITH];
    }
    cmd.de = fm.sat(cmd.de, a.de_max);

    // ---------------- látero-direcional ----------------
    if (in.on_ground) {
        const psiref = g.chip - fm.atan(a.Ky * g.ect + a.Ki * x[S.IE]);
        const uy = a.Kpsi * fm.wrap(psiref - x[S.PSI]) - a.Kr * x[S.R];
        cmd.da = -a.Kphia * x[S.PHI] - a.Kpa * x[S.P];
        cmd.dr = -uy;
        cmd.dw = a.Kbeq * uy * p.steer_sign;
        cmd.phic = 0.0;
        dx[S.PHC] = -x[S.PHC] / a.tau_phi;
    } else {
        // inclinação máxima que a asa sustenta sem perder altura: 1/cos φ <= n_max(α_max)
        const CLlim = a.CL0 + a.CLa * a.alpha_max;
        const nmax = in.qb * p.Sref * CLlim / (in.m * L.g0);
        var philim = if (nmax > 1.0) fm.acos(1.0 / nmax) else 0.0;
        if (philim > a.phimax) philim = a.phimax;
        const phir = if (in.Vg > 3.0) fm.sat(g.phiff + a.Kchi * fm.wrap(g.chid - in.chi), philim) else 0.0;
        dx[S.PHC] = fm.sat((phir - x[S.PHC]) / a.tau_phi, a.pmax_cmd);
        cmd.phic = x[S.PHC];
        cmd.da = a.Kphia * (cmd.phic - x[S.PHI]) - a.Kpa * x[S.P];
        cmd.dr = -a.Kbeta * in.be;
        cmd.dw = 0.0;
    }
    cmd.da = fm.sat(cmd.da, a.da_max);
    cmd.dr = fm.sat(cmd.dr, a.dr_max);
    cmd.dw = fm.sat(cmd.dw, 20.0 * std.math.rad_per_deg);

    // ---------------- integradores ----------------
    const active = autop and noar and f.flare == 0;
    dx[S.IH] = if (active) fm.sat(eh, 3.0) else 0.0;
    const thr_free = a.Dtrim + a.KV * (g.Vseg - in.Va) + a.KIV * x[S.IV] + a.KHT * eh;
    const saturated = (thr_free > 1.0 and g.Vseg > in.Va) or (thr_free < 0.0 and g.Vseg < in.Va);
    dx[S.IV] = if (active and !saturated) g.Vseg - in.Va else 0.0;
    dx[S.ITH] = if (active) fm.sat(in.al - cmd.alc, 5.0 * std.math.rad_per_deg) else 0.0;
    dx[S.IE] = if (in.on_ground) g.ect else 0.0;
    return cmd;
}
