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

/// comandos do piloto automático: superfícies, acelerador e as referências que ele seguiu
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

/// o que o piloto automático lê do voo: velocidades, ângulos, pressão dinâmica, massa
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

/// profundor da decolagem no instante `time`: δe0 até a rotação, depois δe1 com a taxa do servo
fn takeoffElevator(ctx: state.Ctx, time: f64) f64 {
    const takeoff = &ctx.p.takeoff;
    if (ctx.tR < 0.0 or time < ctx.tR) return takeoff.de0;
    var delta = takeoff.de1 - takeoff.de0;
    const max_delta = takeoff.rate_de * (time - ctx.tR);
    if (@abs(delta) > max_delta) delta = fmath.sgn(delta) * max_delta;
    return takeoff.de0 + delta;
}

/// q de uma curva nivelada com inclinação φ
pub fn qTurn(phi: f64, Va: f64) f64 {
    const sph = fmath.sin(phi);
    const cph = fmath.cos(fmath.lim(phi, -75.0 * std.math.rad_per_deg, 75.0 * std.math.rad_per_deg));
    return limits.g0 / @max(Va, 3.0) * sph * sph / cph;
}

/// os comandos no instante `time` e as derivadas dos estados do piloto (referências e integradores) em `state_rates`
pub fn commands(ctx: state.Ctx, time: f64, state_vector: []const f64, input: Input, guide: *const guidance.Guide, state_rates: []f64) Cmd {
    const params = ctx.p;
    const gains = &params.ap;
    const flags = ctx.f;
    var cmd = Cmd{};
    const altitude = -state_vector[state.index(.down)];
    const ground_speed = @max(input.Vg, 3.0);
    const noar = !input.on_ground and flags.brakes == 0 and flags.landed == 0;
    const autop = flags.autop != 0;

    // altura de referência: segue o segmento com taxa limitada
    var rate = fmath.lim(gains.Khr * (guide.hseg - state_vector[state.index(.ref_height)]), -gains.g_down * ground_speed, gains.g_up * ground_speed);
    // prioridade da velocidade: abaixo de Vseg a subida pedida diminui
    if (rate > 0.0) rate *= fmath.lim(1.0 - gains.Kvs * (guide.Vseg - input.Va), 0.0, 1.0);
    state_rates[state.index(.ref_height)] = if (autop) rate else 0.0;
    cmd.href = if (autop) state_vector[state.index(.ref_height)] else guide.hseg;
    cmd.hdref = if (autop) rate else 0.0;
    const height_error = cmd.href - altitude;
    const climb_rate_error = cmd.hdref - input.hdot;

    // ---------------- longitudinal ----------------
    const cph = fmath.cos(fmath.lim(state_vector[state.index(.roll)], -75.0 * std.math.rad_per_deg, 75.0 * std.math.rad_per_deg));
    const qref = qTurn(state_vector[state.index(.roll)], input.Va);
    cmd.alc = input.al;
    if (!autop) {
        cmd.thr = if (flags.brakes != 0) 0.0 else fmath.lim(params.takeoff.rate_thr * time, 0.0, 1.0);
        cmd.de = takeoffElevator(ctx, time);
        if (params.takeoff.alpha_guard != 0 and ctx.tR >= 0.0 and time >= ctx.tR) {
            // proteção de α na decolagem: a mesma lei do voo (α e q) com α pedido = o do estol do avião
            // (alpha_guard_lim, runner.guardAlpha); só pica, nunca cabra mais que o comando de decolagem
            const alim = if (params.alpha_guard_lim > 0.0) params.alpha_guard_lim else gains.alpha_max;
            const de_g = gains.Kae * (input.al - alim) + gains.Kqe * state_vector[state.index(.rate_q)];
            if (de_g > cmd.de) {
                cmd.de = de_g;
                cmd.alim = true;
            }
        }
        cmd.thc = state_vector[state.index(.pitch)];
    } else if (flags.landed != 0) {
        cmd.thc = 0.0;
        cmd.thr = 0.0;
        cmd.de = gains.Kthe * state_vector[state.index(.pitch)] + gains.Kqe * state_vector[state.index(.rate_q)];
    } else {
        // h'' = g (n cos φ − cos γ)  =>  n cos φ = cos γ_ref + Kn_h e_h + Kn_hd e_ḣ + Kn_ih ∫e_h
        const gref = fmath.atan2(cmd.hdref, ground_speed);
        var load_factor = fmath.cos(gref) + gains.Kn_h * height_error + gains.Kn_hd * climb_rate_error + gains.Kn_ih * state_vector[state.index(.int_height)];
        cmd.thr = fmath.lim(gains.Dtrim + gains.KV * (guide.Vseg - input.Va) + gains.KIV * state_vector[state.index(.int_speed)] + gains.KHT * height_error, 0.0, 1.0);
        if (flags.flare != 0) { // arredondamento exponencial: dh/dt = −h_rodas / τ
            const wheel_height = altitude - terrain.height(params, state_vector[state.index(.north)], state_vector[state.index(.east)]) - ctx.h_rest;
            cmd.hdref = -fmath.lim(wheel_height / gains.tau_flare, 0.2, @max(-input.hdot, 0.2));
            load_factor = 1.0 + gains.Kfn * (cmd.hdref - input.hdot);
            if (wheel_height < 0.3) cmd.thr = 0.0;
        }
        load_factor = fmath.lim(load_factor, 0.0, 3.0);
        const CLc = if (input.qb > 5.0) load_factor / cph * input.m * limits.g0 / (input.qb * params.Sref) else gains.CL0;
        const al_free = (CLc - gains.CL0) / gains.CLa;
        cmd.alc = fmath.lim(al_free, -6.0 * std.math.rad_per_deg, gains.alpha_max); // proteção de α
        cmd.alim = al_free >= gains.alpha_max;
        cmd.thc = state_vector[state.index(.pitch)] + (cmd.alc - input.al);
        cmd.de = gains.Kae * (input.al - cmd.alc) + gains.Kqe * (state_vector[state.index(.rate_q)] - qref) + gains.KIa * state_vector[state.index(.int_alpha)];
    }
    cmd.de = fmath.sat(cmd.de, gains.de_max);

    // ---------------- látero-direcional ----------------
    if (input.on_ground) {
        const psiref = guide.chip - fmath.atan(gains.Ky * guide.ect + gains.Ki * state_vector[state.index(.int_track)]);
        const uy = gains.Kpsi * fmath.wrap(psiref - state_vector[state.index(.yaw)]) - gains.Kr * state_vector[state.index(.rate_r)];
        cmd.da = -gains.Kphia * state_vector[state.index(.roll)] - gains.Kpa * state_vector[state.index(.rate_p)];
        cmd.dr = -uy;
        cmd.dw = gains.Kbeq * uy * params.steer_sign;
        cmd.phic = 0.0;
        state_rates[state.index(.bank_cmd)] = -state_vector[state.index(.bank_cmd)] / gains.tau_phi;
    } else {
        // inclinação máxima que a asa sustenta sem perder altura: 1/cos φ <= n_max(α_max)
        const CLlim = gains.CL0 + gains.CLa * gains.alpha_max;
        const nmax = input.qb * params.Sref * CLlim / (input.m * limits.g0);
        var philim = if (nmax > 1.0) fmath.acos(1.0 / nmax) else 0.0;
        if (philim > gains.phimax) philim = gains.phimax;
        const phir = if (input.Vg > 3.0) fmath.sat(guide.phiff + gains.Kchi * fmath.wrap(guide.chid - input.chi), philim) else 0.0;
        state_rates[state.index(.bank_cmd)] = fmath.sat((phir - state_vector[state.index(.bank_cmd)]) / gains.tau_phi, gains.pmax_cmd);
        cmd.phic = state_vector[state.index(.bank_cmd)];
        cmd.da = gains.Kphia * (cmd.phic - state_vector[state.index(.roll)]) - gains.Kpa * state_vector[state.index(.rate_p)];
        cmd.dr = -gains.Kbeta * input.be;
        cmd.dw = 0.0;
    }
    cmd.da = fmath.sat(cmd.da, gains.da_max);
    cmd.dr = fmath.sat(cmd.dr, gains.dr_max);
    cmd.dw = fmath.sat(cmd.dw, 20.0 * std.math.rad_per_deg);

    // ---------------- integradores ----------------
    const active = autop and noar and flags.flare == 0;
    state_rates[state.index(.int_height)] = if (active) fmath.sat(height_error, 3.0) else 0.0;
    const thr_free = gains.Dtrim + gains.KV * (guide.Vseg - input.Va) + gains.KIV * state_vector[state.index(.int_speed)] + gains.KHT * height_error;
    const saturated = (thr_free > 1.0 and guide.Vseg > input.Va) or (thr_free < 0.0 and guide.Vseg < input.Va);
    state_rates[state.index(.int_speed)] = if (active and !saturated) guide.Vseg - input.Va else 0.0;
    state_rates[state.index(.int_alpha)] = if (active) fmath.sat(input.al - cmd.alc, 5.0 * std.math.rad_per_deg) else 0.0;
    state_rates[state.index(.int_track)] = if (input.on_ground) guide.ect else 0.0;
    return cmd;
}
