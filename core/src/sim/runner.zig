//! Executor de uma corrida: eventos discretos, paradas, registro e checkpoints.
//!
//! `run` avança até uma condição de parada, até `t_limit` (fatia para a GUI desenhar
//! em tempo real) ou até o buffer de registro encher, e pode ser chamado de novo para
//! continuar de onde parou. O estado inteiro está em `Run` (POD): copiar seus bytes é
//! o checkpoint.
const std = @import("std");
const guidance = @import("../control/guidance.zig");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const state = @import("state.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const dynamics = @import("dynamics.zig");
const atmosphere = @import("../physics/atmosphere.zig");
const aero = @import("../physics/aero.zig");
const llt = @import("../loads/llt.zig");
const prop = @import("../physics/propulsion.zig");
const mass = @import("../physics/mass.zig");
const trim = @import("trim.zig");
const aeromodel = @import("../physics/aeromodel.zig");
const mods = @import("../modifiers/mod.zig");
const terrain = @import("../physics/terrain.zig");

/// por que `run` voltou
pub const Status = enum(i32) {
    not_ready = -1,
    chunk = 0, // chegou em t_limit (continuar)
    stopped = 1, // condição de parada (stop_*)
    completed = 2, // pousou e parou / fim da decolagem
    timeout = 3, // tmax
    crashed = 4, // abaixo do chão ou divergiu
    buffer_full = 5, // registro cheio (continuar)
};

/// uma simulação: os parâmetros (`p`), o estado da corrida (`r`) e se já foi configurada
pub const Instance = struct {
    p: types.Params = .{},
    r: state.Run = .{},
    configured: bool = false,

    /// a visão somente leitura que a física recebe
    pub fn ctx(self: *const Instance) state.Ctx {
        return .{ .p = &self.p, .f = &self.r.f, .tR = self.r.tR, .h_ground = self.r.h_ground, .tg = self.r.tg, .h_rest = self.r.h_rest };
    }
};

/// o que `configure` recusa: limites estáticos, passo de tempo ou massa inválidos
pub const ConfigError = error{
    TooManySurfaces,
    TooManyProps,
    TooManyGear,
    TooManyTanks,
    TooManySegments,
    TooManyEvents,
    BadTimeStep,
    BadMass,
    TooManyPropPoints,
};

/// o que `resetGround` e `resetAir` recusam
pub const StateError = error{ NotConfigured, BadSegment, TrimFailed, NoGear, BadInertia, Diverged };

/// o que cada erro de estado quer dizer, para mostrar a quem voa (AeroDrive) ou analisa (aerosim)
pub fn stateText(err: StateError) []const u8 {
    return switch (err) {
        error.NotConfigured => "o avião não foi configurado",
        error.BadSegment => "segmento da missão inválido",
        error.TrimFailed => "a trimagem não convergiu",
        error.NoGear => "o avião não tem trem de pouso (o voo começa parado na pista)",
        error.BadInertia => "massa ou inércia inválida (zero, negativa ou NaN): confira a massa e a inércia",
        error.Diverged => "a simulação divergiu ao assentar o avião (estado NaN): confira o trem, a massa e a inércia",
    };
}

/// o que o voo precisa e a configuração (feita também para análises sem voo) não exige
fn checkFlight(params: *const types.Params) StateError!void {
    inline for (.{ params.m_dry, params.Ixx, params.Iyy, params.Izz }) |value| if (!(value > 0) or !std.math.isFinite(value)) return error.BadInertia;
    if (!std.math.isFinite(params.Ixz)) return error.BadInertia;
}

/// verdadeiro se todo o vetor de estados é finito
fn finiteState(state_vector: []const f64) bool {
    for (state_vector) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// `value` como usize, ou `err` se estiver fora de [0, max]
fn count(value: i32, max: usize, err: ConfigError) ConfigError!usize {
    if (value < 0 or value > max) return err;
    return @intCast(value);
}

/// calcula os derivados e valida os limites
pub fn configure(inst: *Instance) ConfigError!void {
    const params = &inst.p;
    inst.configured = false;
    _ = try count(params.n_surf, limits.max_surfaces, error.TooManySurfaces);
    const n_props = try count(params.n_prop, limits.max_props, error.TooManyProps);
    _ = try count(params.n_gear, limits.max_gear, error.TooManyGear);
    _ = try count(params.n_tank, limits.max_tanks, error.TooManyTanks);
    _ = try count(params.n_seg, limits.max_segments, error.TooManySegments);
    _ = try count(params.n_event, limits.max_events, error.TooManyEvents);
    if (!(params.dt > 0)) return error.BadTimeStep;
    if (!(params.m_dry > 0)) return error.BadMass;
    for (params.prop[0..n_props]) |*prop_unit| _ = try count(prop_unit.n_pts, limits.max_prop_pts, error.TooManyPropPoints);
    var xm: f64 = 0;
    var nm: f64 = 0;
    var xs: f64 = 0;
    var ns: f64 = 0;
    for (params.gear[0..@intCast(params.n_gear)]) |*gear_point| {
        if (gear_point.kind == types.gear_main) {
            xm += gear_point.r[0];
            nm += 1;
        } else if (gear_point.kind == types.gear_steer) {
            xs += gear_point.r[0];
            ns += 1;
        }
    }
    params.steer_sign = if (nm > 0 and ns > 0 and xs / ns < xm / nm) -1.0 else 1.0;
    aero.init(params);
    llt.prepare(params); // a geometria fixa da linha sustentadora (cargas e aero_model = 1)
    prop.init(params);
    mass.initTanks(params);
    params.alpha_guard_lim = guardAlpha(params);
    inst.configured = true;
}

/// o α (rad) da proteção de α na decolagem: o primeiro em que a superfície mais carregada chega a ap.kCL do C_Lmax
/// dela (o C_L/C_Lmax do modelo aerodinâmico do voo, em voo livre a 12 m/s, sem comando), varrendo de 0 a 30° de
/// 0,25 em 0,25°. É o estol de cada avião, não um número fixo: o alpha_max do piloto (11°) segura um monoplano que
/// sai do chão a 14° e deixa passar uma asa que estola antes. Sem chegar a kCL até 30°: ap.alpha_max
fn guardAlpha(params: *const types.Params) f64 {
    const step = 0.25 * std.math.rad_per_deg;
    var al: f64 = 0;
    while (al <= 30.0 * std.math.rad_per_deg) : (al += step) {
        const sa = fmath.sincos(al);
        const ae = aeromodel.compute(params, .{ 12.0 * sa.c, 0, 12.0 * sa.s }, vec.zero, vec.zero, 100.0, vec.zero, &mods.Env.none);
        if (ae.ratioCL >= params.ap.kCL) return al;
    }
    return params.ap.alpha_max;
}

/// liga o piloto automático sem degrau: profundor e acelerador continuam de onde estavam
fn syncIntegrators(inst: *Instance, de_before: f64, thr_before: f64) void {
    const gains = &inst.p.ap;
    const state_vector = &inst.r.x;
    state_vector[state.index(.int_alpha)] = 0.0;
    state_vector[state.index(.int_height)] = 0.0;
    var state_rates: [state.nx]f64 = undefined;
    var out: dynamics.Out = .{};
    dynamics.derivatives(inst.ctx(), inst.r.t, state_vector, &state_rates, &out);
    const qref = @import("../control/autopilot.zig").qTurn(state_vector[state.index(.roll)], out.Va);
    state_vector[state.index(.int_alpha)] = if (gains.KIa != 0.0) (de_before - gains.Kae * (out.alfa - out.cmd.alc) - gains.Kqe * (state_vector[state.index(.rate_q)] - qref)) / gains.KIa else 0.0;
    state_vector[state.index(.int_speed)] = if (gains.KIV != 0.0) (thr_before - gains.Dtrim - gains.KV * (out.guide.Vseg - out.Va) - gains.KHT * (out.cmd.href + state_vector[state.index(.down)])) / gains.KIV else 0.0;
}

/// passa do comando de fora para o piloto automático sem tranco: altura de referência = altura
/// atual e integradores ajustados para continuar com o profundor e o acelerador de agora.
/// No ar, o piloto assume já em voo (não volta à lei de decolagem) e retoma o percurso pela perna
/// de cruzeiro mais próxima — nunca por uma perna baixa (passagem LAPES, descida, pouso).
pub fn handover(inst: *Instance) void {
    if (!inst.configured or inst.r.valid == 0) return;
    const de = inst.p.pilot.de;
    const thr = inst.p.pilot.thr;
    const state_vector = &inst.r.x;
    inst.p.pilot.manual = 0;
    state_vector[state.index(.ref_height)] = -state_vector[state.index(.down)];
    state_vector[state.index(.int_track)] = 0.0;
    if (inst.r.f.airborne != 0 and inst.r.f.landed == 0) {
        inst.r.f.autop = 1;
        if (guidance.rejoinSegment(&inst.p, state_vector[state.index(.north)], state_vector[state.index(.east)], -state_vector[state.index(.down)])) |seg_index| inst.r.f.seg = seg_index;
    }
    if (inst.r.f.autop != 0) syncIntegrators(inst, de, thr);
}

/// zera a corrida e marca a carga como já solta quando não há carga
fn resetCommon(inst: *Instance) void {
    inst.r = .{};
    inst.r.f.released = if (inst.p.no_payload != 0 or inst.p.payload.enabled == 0) 1 else 0;
}

/// aeronave parada na cabeceira, freada, até assentar no trem (3 s)
pub fn resetGround(inst: *Instance) StateError!void {
    if (!inst.configured) return error.NotConfigured;
    try checkFlight(&inst.p);
    if (inst.p.n_gear <= 0) return error.NoGear;
    resetCommon(inst);
    const params = &inst.p;
    const run_state = &inst.r;
    run_state.f.brakes = 1;
    var zr: f64 = 0.0;
    var xr: f64 = 0.0;
    var nose: ?[3]f64 = null;
    for (params.gear[0..@intCast(params.n_gear)]) |*gear_point| {
        if (gear_point.kind == types.gear_main) {
            zr = gear_point.r[2];
            xr = gear_point.r[0];
        } else if (gear_point.kind == types.gear_steer) nose = gear_point.r;
    }
    const h0 = terrain.height(params, 0, 0); // mesa: começa em cima dela
    run_state.x[state.index(.down)] = -zr - h0;
    // bequilha à frente e mais comprida que o trem principal (atitude no chão, `power.ground_pitch`): começa já
    // na atitude em que as rodas tocam juntas. Nivelado, a bequilha entraria no chão e o assentamento chutaria o
    // nariz para cima. Nos outros trens nada muda
    if (nose) |nr| if (nr[0] > xr and nr[2] > zr) {
        const pitch = std.math.atan((nr[2] - zr) / (nr[0] - xr));
        run_state.x[state.index(.pitch)] = pitch;
        run_state.x[state.index(.down)] = -h0 - (-xr * @sin(pitch) + zr * @cos(pitch));
    };
    for (0..limits.max_props) |i| run_state.x[state.rps(i)] = 1.0;
    var time: f64 = -3.0;
    while (time < -1e-9) : (time += params.dt) {
        dynamics.rk4(inst.ctx(), time, &run_state.x, params.dt);
        if (!std.math.isFinite(run_state.x[state.index(.vel_x)]) or !std.math.isFinite(run_state.x[state.index(.roll)]) or !std.math.isFinite(run_state.x[state.index(.pitch)])) break;
    }
    if (!finiteState(&run_state.x)) {
        run_state.valid = 0;
        return error.Diverged;
    }
    run_state.x[state.index(.north)] = 0;
    run_state.x[state.index(.east)] = 0;
    run_state.x[state.index(.yaw)] = 0;
    run_state.x[state.index(.vel_x)] = 0;
    run_state.x[state.index(.vel_y)] = 0;
    run_state.x[state.index(.rate_p)] = 0;
    run_state.x[state.index(.rate_r)] = 0;
    inline for (.{ state.index(.int_height), state.index(.int_speed), state.index(.int_alpha), state.index(.int_track), state.index(.ref_height), state.index(.bank_cmd), state.index(.energy) }) |k| run_state.x[k] = 0;
    run_state.h_ground = -run_state.x[state.index(.down)];
    run_state.h_rest = run_state.h_ground - h0;
    run_state.x[state.index(.ref_height)] = run_state.h_ground;
    run_state.f.brakes = 0;
    run_state.t = 0;
    run_state.valid = 1;
}

/// começa em voo equilibrado (nivelado, sem vento lateral) no início do segmento `seg`
pub fn resetAir(inst: *Instance, seg: i32) StateError!void {
    if (!inst.configured) return error.NotConfigured;
    const params = &inst.p;
    if (seg < 0 or seg >= params.n_seg) return error.BadSegment;
    try checkFlight(params);
    resetCommon(inst);
    const run_state = &inst.r;
    const segment = &params.seg[@intCast(seg)];
    const airspeed = segment.V0;
    const tp = trim.solve(trim.Ctx.init(params, &run_state.f), types.trim_level, airspeed, 1.0, null);
    if (tp.ok == 0) return error.TrimFailed;
    run_state.f.seg = seg;
    run_state.f.airborne = 1;
    run_state.f.autop = 1;
    run_state.h_ground = 0;
    for (params.gear[0..@intCast(params.n_gear)]) |*gear_point| if (gear_point.kind == types.gear_main) {
        run_state.h_rest = gear_point.r[2];
    };
    run_state.x[state.index(.north)] = segment.n0;
    run_state.x[state.index(.east)] = segment.e0;
    run_state.x[state.index(.down)] = -segment.h0;
    const chi = if (segment.arc != 0) fmath.atan2(segment.e0 - segment.ce, segment.n0 - segment.cn) + segment.lam * 0.5 * fmath.pi else segment.chi0;
    run_state.x[state.index(.yaw)] = chi;
    run_state.x[state.index(.pitch)] = tp.alpha;
    const sa = fmath.sincos(tp.alpha);
    run_state.x[state.index(.vel_x)] = airspeed * sa.c;
    run_state.x[state.index(.vel_z)] = airspeed * sa.s;
    // começa voando em relação à massa de ar: soma o vento na velocidade em relação ao solo
    const body_to_ned = vec.rotation(0, tp.alpha, chi);
    const WB = vec.mulT(body_to_ned, atmosphere.wind(&params.env, 0, segment.h0, -1));
    run_state.x[state.index(.vel_x)] += WB[0];
    run_state.x[state.index(.vel_y)] += WB[1];
    run_state.x[state.index(.vel_z)] += WB[2];
    const Vr = vec.V3{ airspeed * sa.c, 0, airspeed * sa.s };
    for (params.prop[0..@intCast(params.n_prop)], 0..) |*prop_unit, i| run_state.x[state.rps(i)] = prop.equilibriumRps(params, prop_unit, Vr, tp.thr);
    run_state.x[state.index(.ref_height)] = segment.h0;
    run_state.ev.tLO = 0;
    run_state.ev.tHt = 0;
    run_state.ev.tR = 0;
    run_state.tR = 0;
    run_state.t = 0;
    run_state.valid = 1;
    syncIntegrators(inst, tp.de, tp.thr);
}

/// uma linha do registro com o estado e as saídas do instante
fn writeRow(inst: *const Instance, row: *types.LogRow, out: *const dynamics.Out) void {
    const params = &inst.p;
    const run_state = &inst.r;
    const state_vector = &run_state.x;
    row.* = std.mem.zeroes(types.LogRow);
    row.t = run_state.t;
    row.seg = @floatFromInt(run_state.f.seg);
    row.n = state_vector[state.index(.north)];
    row.e = state_vector[state.index(.east)];
    row.h = -state_vector[state.index(.down)];
    row.phi = state_vector[state.index(.roll)];
    row.theta = state_vector[state.index(.pitch)];
    row.psi = state_vector[state.index(.yaw)];
    row.p = state_vector[state.index(.rate_p)];
    row.q = state_vector[state.index(.rate_q)];
    row.r = state_vector[state.index(.rate_r)];
    row.Va = out.Va;
    row.Vg = out.Vg;
    row.alpha = out.alfa;
    row.beta = out.beta;
    row.gamma = out.gama;
    row.chi = out.chi;
    row.s = out.guide.s;
    row.ect = out.guide.ect;
    row.hseg = out.guide.hseg;
    row.href = out.cmd.href;
    row.Vref = out.guide.Vseg;
    row.thc = out.cmd.thc;
    row.alc = out.cmd.alc;
    row.phic = out.cmd.phic;
    row.CL = out.CL;
    row.CD = out.CD;
    row.CDi = out.CDi;
    row.CY = out.CY;
    row.CL_wing = out.CLgr[0];
    row.CL_ht = out.CLgr[1];
    row.CY_vt = out.CLgr[2];
    row.CL_fus = out.CLgr[3];
    row.ratioCL = out.ratioCL;
    row.T = out.pr.T;
    row.Q = out.pr.Q;
    row.P = out.pr.P;
    row.Ibat = out.pr.Ibat;
    row.Vbus = out.pr.Vbus;
    row.E = state_vector[state.index(.energy)] / 3600.0;
    row.thr = out.cmd.thr;
    row.de = out.cmd.de;
    row.da = out.cmd.da;
    row.dr = out.cmd.dr;
    row.dw = out.cmd.dw;
    for (params.gear[0..@intCast(params.n_gear)], 0..) |*gear_point, i| {
        row.Ngear[i] = out.N[i];
        switch (gear_point.kind) {
            types.gear_steer => row.N_steer += out.N[i],
            types.gear_main => row.N_main += out.N[i],
            else => row.N_skid += out.N[i],
        }
    }
    row.htail = out.htail;
    row.hprop = out.hprop;
    row.RN = out.RN;
    row.Rnw = out.Rnw;
    row.Rmw = out.Rmw;
    row.hdot = out.hdot;
    row.nz = out.nz;
    row.alim = if (out.cmd.alim) 1 else 0;
    row.m = out.m;
    row.xcg = out.rcg[0];
    row.ycg = out.rcg[1];
    row.zcg = out.rcg[2];
    row.Ixx = out.I[0][0];
    row.Iyy = out.I[1][1];
    row.Izz = out.I[2][2];
    row.Fslx = out.Fsl[0];
    row.Fsly = out.Fsl[1];
    row.sL = state_vector[state.index(.cargo_slide)];
    const comps = [_]vec.V3{ out.Mgr[0], out.Mgr[1], out.Mgr[2], out.Mgr[3], out.Mprop, out.Mgyro, out.Mgear, out.Mliq, out.Mpay, out.Mt };
    const Lf = [_]*f64{ &row.L_wing, &row.L_ht, &row.L_vt, &row.L_fus, &row.L_prop, &row.L_gyro, &row.L_gear, &row.L_liq, &row.L_pay, &row.L_tot };
    const Mf = [_]*f64{ &row.M_wing, &row.M_ht, &row.M_vt, &row.M_fus, &row.M_prop, &row.M_gyro, &row.M_gear, &row.M_liq, &row.M_pay, &row.M_tot };
    const Nf = [_]*f64{ &row.N_wing, &row.N_ht, &row.N_vt, &row.N_fus, &row.N_prop, &row.N_gyro, &row.N_gear, &row.N_liq, &row.N_pay, &row.N_tot };
    for (comps, 0..) |moment, k| {
        Lf[k].* = moment[0];
        Mf[k].* = moment[1];
        Nf[k].* = moment[2];
    }
    row.Wn = out.W[0];
    row.We = out.W[1];
    row.Wd = out.W[2];
    if (run_state.f.pk_flying != 0 or run_state.ev.pk_t > 0) {
        row.pk_n = if (run_state.f.pk_flying != 0) run_state.pk[0] else run_state.ev.pk_n;
        row.pk_e = if (run_state.f.pk_flying != 0) run_state.pk[1] else run_state.ev.pk_e;
        row.pk_h = if (run_state.f.pk_flying != 0) -run_state.pk[2] else 0;
    }
    row.hgnd = terrain.height(params, state_vector[state.index(.north)], state_vector[state.index(.east)]);
    row.hw = -state_vector[state.index(.down)] - row.hgnd - run_state.h_rest;
    for (0..@intCast(params.n_prop)) |i| {
        row.rpm[i] = state_vector[state.rps(i)] * 60.0;
        row.thrust[i] = out.pr.u[i].T;
        row.current[i] = out.pr.u[i].I;
    }
    for (0..@intCast(params.n_tank)) |i| {
        row.slosh_x[i] = state_vector[state.sx(i)];
        row.slosh_y[i] = state_vector[state.sy(i)];
    }
}

/// avança a corrida até uma parada, até `t_limit` ou até encher `log`; `nrows` = linhas escritas
pub fn run(inst: *Instance, t_limit: f64, log: []types.LogRow, nrows: *usize) Status {
    nrows.* = 0;
    if (!inst.configured or inst.r.valid == 0) return .not_ready;
    const params = &inst.p;
    const run_state = &inst.r;
    const state_vector = &run_state.x;
    const events = &run_state.ev;
    var state_rates: [state.nx]f64 = undefined;
    var out: dynamics.Out = .{};
    events.stopped = 0;
    var status: Status = .chunk;

    while (true) {
        const log_due = run_state.t >= run_state.next_log - 1e-9;
        if (run_state.t >= t_limit) return .chunk;
        if (log_due and nrows.* >= log.len and log.len > 0) return .buffer_full;

        dynamics.derivatives(inst.ctx(), run_state.t, state_vector, &state_rates, &out);
        const time = run_state.t;
        const altitude = -state_vector[state.index(.down)];
        var contact = false;
        var steer = false;
        var main = false;
        for (params.gear[0..@intCast(params.n_gear)], 0..) |*gear_point, i| {
            if (out.N[i] > 0.0) {
                contact = true;
                if (gear_point.kind == types.gear_steer) steer = true;
                if (gear_point.kind == types.gear_main) main = true;
            }
        }
        const segment = &params.seg[@intCast(run_state.f.seg)];
        const hgnd = terrain.height(params, state_vector[state.index(.north)], state_vector[state.index(.east)]);
        const hw = altitude - hgnd - run_state.h_rest; // rodas sobre o terreno local (chão, mesa ou plataforma)

        // ---- decolagem: profundor por velocidade (VR) ou distância (sR) ----
        const pull = if (params.takeoff.sR > 0.0) state_vector[state.index(.north)] >= params.takeoff.sR else out.Va >= params.takeoff.VR;
        if (run_state.f.autop == 0 and run_state.tR < 0.0 and pull) {
            run_state.tR = time;
            events.tR = time;
        }
        if (segment.takeoff != 0 and events.tRot < 0.0 and !steer and time > 0.05) {
            events.tRot = time;
            events.nRot = state_vector[state.index(.north)];
        }
        if (run_state.f.airborne == 0 and !contact and hw > 0.005) {
            run_state.f.airborne = 1;
            events.tLO = time;
            events.nLO = state_vector[state.index(.north)];
            events.VLO = out.Va;
            events.thLO = state_vector[state.index(.pitch)];
        }
        // referência de altura com catraca (não devolve altura já ganha rumo ao alvo)
        if (run_state.f.autop != 0 and run_state.f.flare == 0 and run_state.f.landed == 0 and segment.landing == 0) {
            if (out.guide.hseg > state_vector[state.index(.ref_height)] and altitude > state_vector[state.index(.ref_height)]) state_vector[state.index(.ref_height)] = @min(altitude, out.guide.hseg) else if (out.guide.hseg < state_vector[state.index(.ref_height)] and altitude < state_vector[state.index(.ref_height)]) state_vector[state.index(.ref_height)] = @max(altitude, out.guide.hseg);
        }
        var switched_on = false;
        if (run_state.f.airborne != 0 and run_state.f.autop == 0 and hw >= params.takeoff.ht) {
            run_state.f.autop = 1;
            state_vector[state.index(.ref_height)] = altitude;
            switched_on = true;
            syncIntegrators(inst, out.cmd.de, 1.0);
            events.tHt = time;
            events.nHt = state_vector[state.index(.north)];
            events.VHt = out.Va;
            events.gHt = out.gama;
        }
        if (run_state.f.airborne != 0 and segment.takeoff != 0) events.sink = @max(events.sink, run_state.h_ground - altitude); // z da decolagem
        if (run_state.f.airborne != 0 and run_state.f.autop == 0) events.hw_min_air = @min(events.hw_min_air, hw);
        if (segment.takeoff != 0) {
            events.hcmin = @min(events.hcmin, out.htail);
            if (out.Va > 4.0) events.ratio_to = @max(events.ratio_to, out.ratioCL);
            events.qpeak_to = @max(events.qpeak_to, @abs(state_vector[state.index(.rate_q)]));
        }
        if (run_state.f.airborne != 0 and run_state.f.landed == 0 and contact and segment.landing == 0) events.bounced = 1;
        if (out.Va > 4.0) events.ratio_mission = @max(events.ratio_mission, out.ratioCL);
        events.Ipeak = @max(events.Ipeak, out.pr.Ibat);

        // ---- percurso e eventos ----
        var switched = false;
        if (segment.landing == 0 and run_state.f.seg < params.n_seg - 1 and out.guide.s >= segment.L) {
            if (segment.takeoff != 0) events.E_to = state_vector[state.index(.energy)] / 3600.0;
            run_state.f.seg += 1;
            switched = true;
        }
        if (params.pilot.drop != 0 and run_state.f.released == 0 and run_state.f.extracting == 0) { // soltura pedida de fora
            run_state.f.extracting = 1;
            events.tdrop = time;
            events.ndrop = state_vector[state.index(.north)];
            events.hdrop = altitude;
        }
        if (!switched) {
            for (params.event[0..@intCast(params.n_event)], 0..) |*event, k| {
                if (run_state.f.ev_done[k] != 0 or run_state.f.seg != event.seg or out.guide.s < event.s) continue;
                if (params.pilot.manual != 0 and event.kind != types.event_gust) continue; // no manual, quem solta é o piloto
                run_state.f.ev_done[k] = 1;
                if (event.kind == types.event_gust) {
                    run_state.tg = time;
                    events.tg = time;
                } else if (run_state.f.released == 0) {
                    run_state.f.extracting = 1;
                    events.tdrop = time;
                    events.ndrop = state_vector[state.index(.north)];
                    events.hdrop = altitude;
                }
            }
        }
        if (run_state.f.extracting != 0 and run_state.f.released == 0 and state_vector[state.index(.cargo_slide)] >= params.payload.bay) {
            run_state.f.released = 1;
            events.trel = time;
            const body_to_ned = vec.rotation(state_vector[state.index(.roll)], state_vector[state.index(.pitch)], state_vector[state.index(.yaw)]);
            const rL = vec.V3{ params.payload.r[0] - state_vector[state.index(.cargo_slide)], params.payload.r[1], params.payload.r[2] };
            const body_rates = vec.V3{ state_vector[state.index(.rate_p)], state_vector[state.index(.rate_q)], state_vector[state.index(.rate_r)] };
            const pc = vec.mul(body_to_ned, rL);
            var vb = vec.V3{ state_vector[state.index(.vel_x)], state_vector[state.index(.vel_y)], state_vector[state.index(.vel_z)] } + vec.cross(body_rates, rL);
            vb[0] -= state_vector[state.index(.cargo_slide_rate)];
            const vn = vec.mul(body_to_ned, vb);
            run_state.pk = .{ state_vector[state.index(.north)] + pc[0], state_vector[state.index(.east)] + pc[1], state_vector[state.index(.down)] + pc[2], vn[0], vn[1], vn[2] };
            run_state.f.pk_flying = 1;
        }
        if (run_state.f.pk_flying != 0) { // carga com paraquedas (Euler explícito, desacoplada)
            const wind_ned = atmosphere.wind(&params.env, time, -run_state.pk[2], run_state.tg);
            const vr = vec.V3{ run_state.pk[3] - wind_ned[0], run_state.pk[4] - wind_ned[1], run_state.pk[5] - wind_ned[2] };
            const Vv = vec.norm(vr);
            inline for (0..3) |i| {
                const accp = -0.5 * params.env.rho * Vv * params.payload.CdS_chute * vr[i] / params.payload.m + (if (i == 2) limits.g0 else 0.0);
                run_state.pk[3 + i] += accp * params.dt;
                run_state.pk[i] += run_state.pk[3 + i] * params.dt;
            }
            if (run_state.pk[2] >= 0.0) {
                run_state.f.pk_flying = 0;
                events.pk_n = run_state.pk[0];
                events.pk_e = run_state.pk[1];
                events.pk_t = time;
            }
        }
        if (segment.landing != 0 and hw < params.ap.hflare) run_state.f.flare = 1;
        if (segment.landing != 0 and run_state.f.landed == 0 and main) {
            run_state.f.landed = 1;
            events.tTD = time;
            events.nTD = state_vector[state.index(.north)];
            events.hgnd_td = hgnd;
        }

        // ---- registro ----
        if (log_due) {
            if (log.len > 0) {
                writeRow(inst, &log[nrows.*], &out);
                nrows.* += 1;
            }
            run_state.next_log += params.dtlog;
            if (run_state.next_log < time) run_state.next_log = time + params.dtlog;
        }

        // ---- paradas ----
        const stop = (params.stop_seg >= 0 and run_state.f.seg == params.stop_seg and switched) or
            (params.stop_t > 0 and time >= params.stop_t) or (params.stop_autop != 0 and switched_on);
        if (stop) {
            events.stopped = 1;
            status = .stopped;
            break;
        }
        if (run_state.f.landed != 0 and out.Vg < 0.3) {
            events.nStop = state_vector[state.index(.north)];
            events.completed = 1;
            status = .completed;
            break;
        }
        if (params.stop_takeoff != 0 and run_state.f.autop != 0 and hw >= params.takeoff.h_end) {
            events.completed = 1;
            status = .completed;
            break;
        }
        if (time >= params.tmax) {
            status = .timeout;
            break;
        }
        events.hpmin = @min(events.hpmin, out.hprop);
        // a ponta da pá tocou o chão: o voo falha
        if (params.prop_strike != 0 and out.hprop < 0) {
            events.tprop = time;
            status = .crashed;
            break;
        }
        // abaixo do chão, divergiu ou capotou (tocando o chão com mais de 80° de inclinação)
        if (altitude < hgnd - 1.0 or !std.math.isFinite(state_vector[state.index(.vel_x)]) or !std.math.isFinite(state_vector[state.index(.roll)]) or
            !std.math.isFinite(state_vector[state.index(.pitch)]) or (contact and @abs(fmath.wrap(state_vector[state.index(.roll)])) > 1.4))
        {
            status = .crashed;
            break;
        }
        dynamics.rk4(inst.ctx(), time, state_vector, params.dt);
        run_state.t = time + params.dt;
    }
    events.tend = run_state.t;
    events.E = state_vector[state.index(.energy)] / 3600.0;
    return status;
}
