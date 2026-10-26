//! Executor de uma corrida: eventos discretos, paradas, registro e checkpoints.
//!
//! `run` avança até uma condição de parada, até `t_limit` (fatia para a GUI desenhar
//! em tempo real) ou até o buffer de registro encher, e pode ser chamado de novo para
//! continuar de onde parou. O estado inteiro está em `Run` (POD): copiar seus bytes é
//! o checkpoint.
const std = @import("std");
const guidance = @import("../control/guidance.zig");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const S = @import("state.zig");
const fm = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const dyn = @import("dynamics.zig");
const atm = @import("../physics/atmosphere.zig");
const aero = @import("../physics/aero.zig");
const llt = @import("../loads/llt.zig");
const prop = @import("../physics/propulsion.zig");
const mass = @import("../physics/mass.zig");
const trim = @import("trim.zig");
const aeromodel = @import("../physics/aeromodel.zig");
const mods = @import("../modifiers/mod.zig");
const terrain = @import("../physics/terrain.zig");

pub const Status = enum(i32) {
    not_ready = -1,
    chunk = 0, // chegou em t_limit (continuar)
    stopped = 1, // condição de parada (stop_*)
    completed = 2, // pousou e parou / fim da decolagem
    timeout = 3, // tmax
    crashed = 4, // abaixo do chão ou divergiu
    buffer_full = 5, // registro cheio (continuar)
};

pub const Instance = struct {
    p: T.Params = .{},
    r: S.Run = .{},
    configured: bool = false,

    pub fn ctx(self: *const Instance) S.Ctx {
        return .{ .p = &self.p, .f = &self.r.f, .tR = self.r.tR, .h_ground = self.r.h_ground, .tg = self.r.tg, .h_rest = self.r.h_rest };
    }
};

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

pub const StateError = error{ NotConfigured, BadSegment, TrimFailed, NoGear, BadInertia, Diverged };

/// o que cada erro de estado quer dizer, para mostrar a quem voa (AeroDrive) ou analisa (aerosim)
pub fn stateText(e: StateError) []const u8 {
    return switch (e) {
        error.NotConfigured => "o avião não foi configurado",
        error.BadSegment => "segmento da missão inválido",
        error.TrimFailed => "a trimagem não convergiu",
        error.NoGear => "o avião não tem trem de pouso (o voo começa parado na pista)",
        error.BadInertia => "massa ou inércia inválida (zero, negativa ou NaN): confira a massa e a inércia",
        error.Diverged => "a simulação divergiu ao assentar o avião (estado NaN): confira o trem, a massa e a inércia",
    };
}

/// o que o voo precisa e a configuração (feita também para análises sem voo) não exige
fn checkFlight(p: *const T.Params) StateError!void {
    inline for (.{ p.m_dry, p.Ixx, p.Iyy, p.Izz }) |v| if (!(v > 0) or !std.math.isFinite(v)) return error.BadInertia;
    if (!std.math.isFinite(p.Ixz)) return error.BadInertia;
}

fn finiteState(x: []const f64) bool {
    for (x) |v| if (!std.math.isFinite(v)) return false;
    return true;
}

fn count(n: i32, max: usize, e: ConfigError) ConfigError!usize {
    if (n < 0 or n > max) return e;
    return @intCast(n);
}

/// calcula os derivados e valida os limites
pub fn configure(inst: *Instance) ConfigError!void {
    const p = &inst.p;
    inst.configured = false;
    _ = try count(p.n_surf, L.max_surfaces, error.TooManySurfaces);
    const np = try count(p.n_prop, L.max_props, error.TooManyProps);
    _ = try count(p.n_gear, L.max_gear, error.TooManyGear);
    _ = try count(p.n_tank, L.max_tanks, error.TooManyTanks);
    _ = try count(p.n_seg, L.max_segments, error.TooManySegments);
    _ = try count(p.n_event, L.max_events, error.TooManyEvents);
    if (!(p.dt > 0)) return error.BadTimeStep;
    if (!(p.m_dry > 0)) return error.BadMass;
    for (p.prop[0..np]) |*u| _ = try count(u.n_pts, L.max_prop_pts, error.TooManyPropPoints);
    var xm: f64 = 0;
    var nm: f64 = 0;
    var xs: f64 = 0;
    var ns: f64 = 0;
    for (p.gear[0..@intCast(p.n_gear)]) |*g| {
        if (g.kind == T.gear_main) {
            xm += g.r[0];
            nm += 1;
        } else if (g.kind == T.gear_steer) {
            xs += g.r[0];
            ns += 1;
        }
    }
    p.steer_sign = if (nm > 0 and ns > 0 and xs / ns < xm / nm) -1.0 else 1.0;
    aero.init(p);
    llt.prepare(p); // a geometria fixa da linha sustentadora (cargas e aero_model = 1)
    prop.init(p);
    mass.initTanks(p);
    p.alpha_guard_lim = guardAlpha(p);
    inst.configured = true;
}

/// o α (rad) da proteção de α na decolagem: o primeiro em que a superfície mais carregada chega a ap.kCL do C_Lmax
/// dela (o C_L/C_Lmax do modelo aerodinâmico do voo, em voo livre a 12 m/s, sem comando), varrendo de 0 a 30° de
/// 0,25 em 0,25°. É o estol de cada avião, não um número fixo: o alpha_max do piloto (11°) segura um monoplano que
/// sai do chão a 14° e deixa passar uma asa que estola antes. Sem chegar a kCL até 30°: ap.alpha_max
fn guardAlpha(p: *const T.Params) f64 {
    const step = 0.25 * std.math.rad_per_deg;
    var al: f64 = 0;
    while (al <= 30.0 * std.math.rad_per_deg) : (al += step) {
        const sa = fm.sincos(al);
        const ae = aeromodel.compute(p, .{ 12.0 * sa.c, 0, 12.0 * sa.s }, vec.zero, vec.zero, 100.0, vec.zero, &mods.Env.none);
        if (ae.ratioCL >= p.ap.kCL) return al;
    }
    return p.ap.alpha_max;
}

/// liga o piloto automático sem degrau: profundor e acelerador continuam de onde estavam
fn syncIntegrators(inst: *Instance, de_before: f64, thr_before: f64) void {
    const a = &inst.p.ap;
    const x = &inst.r.x;
    x[S.ITH] = 0.0;
    x[S.IH] = 0.0;
    var dx: [S.nx]f64 = undefined;
    var o: dyn.Out = .{};
    dyn.f(inst.ctx(), inst.r.t, x, &dx, &o);
    const qref = @import("../control/autopilot.zig").qTurn(x[S.PHI], o.Va);
    x[S.ITH] = if (a.KIa != 0.0) (de_before - a.Kae * (o.alfa - o.c.alc) - a.Kqe * (x[S.Q] - qref)) / a.KIa else 0.0;
    x[S.IV] = if (a.KIV != 0.0) (thr_before - a.Dtrim - a.KV * (o.g.Vseg - o.Va) - a.KHT * (o.c.href + x[S.D])) / a.KIV else 0.0;
}

/// passa do comando de fora para o piloto automático sem tranco: altura de referência = altura
/// atual e integradores ajustados para continuar com o profundor e o acelerador de agora.
/// No ar, o piloto assume já em voo (não volta à lei de decolagem) e retoma o percurso pela perna
/// de cruzeiro mais próxima — nunca por uma perna baixa (passagem LAPES, descida, pouso).
pub fn handover(inst: *Instance) void {
    if (!inst.configured or inst.r.valid == 0) return;
    const de = inst.p.pilot.de;
    const thr = inst.p.pilot.thr;
    const x = &inst.r.x;
    inst.p.pilot.manual = 0;
    x[S.HR] = -x[S.D];
    x[S.IE] = 0.0;
    if (inst.r.f.airborne != 0 and inst.r.f.landed == 0) {
        inst.r.f.autop = 1;
        if (guidance.rejoinSegment(&inst.p, x[S.N], x[S.E], -x[S.D])) |k| inst.r.f.seg = k;
    }
    if (inst.r.f.autop != 0) syncIntegrators(inst, de, thr);
}

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
    const p = &inst.p;
    const r = &inst.r;
    r.f.brakes = 1;
    var zr: f64 = 0.0;
    var xr: f64 = 0.0;
    var nose: ?[3]f64 = null;
    for (p.gear[0..@intCast(p.n_gear)]) |*g| {
        if (g.kind == T.gear_main) {
            zr = g.r[2];
            xr = g.r[0];
        } else if (g.kind == T.gear_steer) nose = g.r;
    }
    const h0 = terrain.height(p, 0, 0); // mesa: começa em cima dela
    r.x[S.D] = -zr - h0;
    // bequilha à frente e mais comprida que o trem principal (atitude no chão, `power.ground_pitch`): começa já
    // na atitude em que as rodas tocam juntas. Nivelado, a bequilha entraria no chão e o assentamento chutaria o
    // nariz para cima. Nos outros trens nada muda
    if (nose) |nr| if (nr[0] > xr and nr[2] > zr) {
        const th = std.math.atan((nr[2] - zr) / (nr[0] - xr));
        r.x[S.THE] = th;
        r.x[S.D] = -h0 - (-xr * @sin(th) + zr * @cos(th));
    };
    for (0..L.max_props) |i| r.x[S.rps(i)] = 1.0;
    var t: f64 = -3.0;
    while (t < -1e-9) : (t += p.dt) {
        dyn.rk4(inst.ctx(), t, &r.x, p.dt);
        if (!std.math.isFinite(r.x[S.U]) or !std.math.isFinite(r.x[S.PHI]) or !std.math.isFinite(r.x[S.THE])) break;
    }
    if (!finiteState(&r.x)) {
        r.valid = 0;
        return error.Diverged;
    }
    r.x[S.N] = 0;
    r.x[S.E] = 0;
    r.x[S.PSI] = 0;
    r.x[S.U] = 0;
    r.x[S.V] = 0;
    r.x[S.P] = 0;
    r.x[S.R] = 0;
    inline for (.{ S.IH, S.IV, S.ITH, S.IE, S.HR, S.PHC, S.EN }) |k| r.x[k] = 0;
    r.h_ground = -r.x[S.D];
    r.h_rest = r.h_ground - h0;
    r.x[S.HR] = r.h_ground;
    r.f.brakes = 0;
    r.t = 0;
    r.valid = 1;
}

/// começa em voo equilibrado (nivelado, sem vento lateral) no início do segmento `seg`
pub fn resetAir(inst: *Instance, seg: i32) StateError!void {
    if (!inst.configured) return error.NotConfigured;
    const p = &inst.p;
    if (seg < 0 or seg >= p.n_seg) return error.BadSegment;
    try checkFlight(p);
    resetCommon(inst);
    const r = &inst.r;
    const sg = &p.seg[@intCast(seg)];
    const V = sg.V0;
    const tp = trim.solve(trim.Ctx.init(p, &r.f), T.trim_level, V, 1.0, null);
    if (tp.ok == 0) return error.TrimFailed;
    r.f.seg = seg;
    r.f.airborne = 1;
    r.f.autop = 1;
    r.h_ground = 0;
    for (p.gear[0..@intCast(p.n_gear)]) |*g| if (g.kind == T.gear_main) {
        r.h_rest = g.r[2];
    };
    r.x[S.N] = sg.n0;
    r.x[S.E] = sg.e0;
    r.x[S.D] = -sg.h0;
    const chi = if (sg.arc != 0) fm.atan2(sg.e0 - sg.ce, sg.n0 - sg.cn) + sg.lam * 0.5 * fm.pi else sg.chi0;
    r.x[S.PSI] = chi;
    r.x[S.THE] = tp.alpha;
    const sa = fm.sincos(tp.alpha);
    r.x[S.U] = V * sa.c;
    r.x[S.W] = V * sa.s;
    // começa voando em relação à massa de ar: soma o vento na velocidade em relação ao solo
    const R = vec.rotation(0, tp.alpha, chi);
    const WB = vec.mulT(R, atm.wind(&p.env, 0, sg.h0, -1));
    r.x[S.U] += WB[0];
    r.x[S.V] += WB[1];
    r.x[S.W] += WB[2];
    const Vr = vec.V3{ V * sa.c, 0, V * sa.s };
    for (p.prop[0..@intCast(p.n_prop)], 0..) |*u, i| r.x[S.rps(i)] = prop.equilibriumRps(p, u, Vr, tp.thr);
    r.x[S.HR] = sg.h0;
    r.ev.tLO = 0;
    r.ev.tHt = 0;
    r.ev.tR = 0;
    r.tR = 0;
    r.t = 0;
    r.valid = 1;
    syncIntegrators(inst, tp.de, tp.thr);
}

fn writeRow(inst: *const Instance, row: *T.LogRow, o: *const dyn.Out) void {
    const p = &inst.p;
    const r = &inst.r;
    const x = &r.x;
    row.* = std.mem.zeroes(T.LogRow);
    row.t = r.t;
    row.seg = @floatFromInt(r.f.seg);
    row.n = x[S.N];
    row.e = x[S.E];
    row.h = -x[S.D];
    row.phi = x[S.PHI];
    row.theta = x[S.THE];
    row.psi = x[S.PSI];
    row.p = x[S.P];
    row.q = x[S.Q];
    row.r = x[S.R];
    row.Va = o.Va;
    row.Vg = o.Vg;
    row.alpha = o.alfa;
    row.beta = o.beta;
    row.gamma = o.gama;
    row.chi = o.chi;
    row.s = o.g.s;
    row.ect = o.g.ect;
    row.hseg = o.g.hseg;
    row.href = o.c.href;
    row.Vref = o.g.Vseg;
    row.thc = o.c.thc;
    row.alc = o.c.alc;
    row.phic = o.c.phic;
    row.CL = o.CL;
    row.CD = o.CD;
    row.CDi = o.CDi;
    row.CY = o.CY;
    row.CL_wing = o.CLgr[0];
    row.CL_ht = o.CLgr[1];
    row.CY_vt = o.CLgr[2];
    row.CL_fus = o.CLgr[3];
    row.ratioCL = o.ratioCL;
    row.T = o.pr.T;
    row.Q = o.pr.Q;
    row.P = o.pr.P;
    row.Ibat = o.pr.Ibat;
    row.Vbus = o.pr.Vbus;
    row.E = x[S.EN] / 3600.0;
    row.thr = o.c.thr;
    row.de = o.c.de;
    row.da = o.c.da;
    row.dr = o.c.dr;
    row.dw = o.c.dw;
    for (p.gear[0..@intCast(p.n_gear)], 0..) |*g, i| {
        row.Ngear[i] = o.N[i];
        switch (g.kind) {
            T.gear_steer => row.N_steer += o.N[i],
            T.gear_main => row.N_main += o.N[i],
            else => row.N_skid += o.N[i],
        }
    }
    row.htail = o.htail;
    row.hprop = o.hprop;
    row.RN = o.RN;
    row.Rnw = o.Rnw;
    row.Rmw = o.Rmw;
    row.hdot = o.hdot;
    row.nz = o.nz;
    row.alim = if (o.c.alim) 1 else 0;
    row.m = o.m;
    row.xcg = o.rcg[0];
    row.ycg = o.rcg[1];
    row.zcg = o.rcg[2];
    row.Ixx = o.I[0][0];
    row.Iyy = o.I[1][1];
    row.Izz = o.I[2][2];
    row.Fslx = o.Fsl[0];
    row.Fsly = o.Fsl[1];
    row.sL = x[S.SL];
    const comps = [_]vec.V3{ o.Mgr[0], o.Mgr[1], o.Mgr[2], o.Mgr[3], o.Mprop, o.Mgyro, o.Mgear, o.Mliq, o.Mpay, o.Mt };
    const Lf = [_]*f64{ &row.L_wing, &row.L_ht, &row.L_vt, &row.L_fus, &row.L_prop, &row.L_gyro, &row.L_gear, &row.L_liq, &row.L_pay, &row.L_tot };
    const Mf = [_]*f64{ &row.M_wing, &row.M_ht, &row.M_vt, &row.M_fus, &row.M_prop, &row.M_gyro, &row.M_gear, &row.M_liq, &row.M_pay, &row.M_tot };
    const Nf = [_]*f64{ &row.N_wing, &row.N_ht, &row.N_vt, &row.N_fus, &row.N_prop, &row.N_gyro, &row.N_gear, &row.N_liq, &row.N_pay, &row.N_tot };
    for (comps, 0..) |m, k| {
        Lf[k].* = m[0];
        Mf[k].* = m[1];
        Nf[k].* = m[2];
    }
    row.Wn = o.W[0];
    row.We = o.W[1];
    row.Wd = o.W[2];
    if (r.f.pk_flying != 0 or r.ev.pk_t > 0) {
        row.pk_n = if (r.f.pk_flying != 0) r.pk[0] else r.ev.pk_n;
        row.pk_e = if (r.f.pk_flying != 0) r.pk[1] else r.ev.pk_e;
        row.pk_h = if (r.f.pk_flying != 0) -r.pk[2] else 0;
    }
    row.hgnd = terrain.height(p, x[S.N], x[S.E]);
    row.hw = -x[S.D] - row.hgnd - r.h_rest;
    for (0..@intCast(p.n_prop)) |i| {
        row.rpm[i] = x[S.rps(i)] * 60.0;
        row.thrust[i] = o.pr.u[i].T;
        row.current[i] = o.pr.u[i].I;
    }
    for (0..@intCast(p.n_tank)) |i| {
        row.slosh_x[i] = x[S.sx(i)];
        row.slosh_y[i] = x[S.sy(i)];
    }
}

pub fn run(inst: *Instance, t_limit: f64, log: []T.LogRow, nrows: *usize) Status {
    nrows.* = 0;
    if (!inst.configured or inst.r.valid == 0) return .not_ready;
    const p = &inst.p;
    const r = &inst.r;
    const x = &r.x;
    const v = &r.ev;
    var dx: [S.nx]f64 = undefined;
    var o: dyn.Out = .{};
    v.stopped = 0;
    var status: Status = .chunk;

    while (true) {
        const log_due = r.t >= r.next_log - 1e-9;
        if (r.t >= t_limit) return .chunk;
        if (log_due and nrows.* >= log.len and log.len > 0) return .buffer_full;

        dyn.f(inst.ctx(), r.t, x, &dx, &o);
        const t = r.t;
        const h = -x[S.D];
        var contact = false;
        var steer = false;
        var main = false;
        for (p.gear[0..@intCast(p.n_gear)], 0..) |*g, i| {
            if (o.N[i] > 0.0) {
                contact = true;
                if (g.kind == T.gear_steer) steer = true;
                if (g.kind == T.gear_main) main = true;
            }
        }
        const sg = &p.seg[@intCast(r.f.seg)];
        const hgnd = terrain.height(p, x[S.N], x[S.E]);
        const hw = h - hgnd - r.h_rest; // rodas sobre o terreno local (chão, mesa ou plataforma)

        // ---- decolagem: profundor por velocidade (VR) ou distância (sR) ----
        const pull = if (p.takeoff.sR > 0.0) x[S.N] >= p.takeoff.sR else o.Va >= p.takeoff.VR;
        if (r.f.autop == 0 and r.tR < 0.0 and pull) {
            r.tR = t;
            v.tR = t;
        }
        if (sg.takeoff != 0 and v.tRot < 0.0 and !steer and t > 0.05) {
            v.tRot = t;
            v.nRot = x[S.N];
        }
        if (r.f.airborne == 0 and !contact and hw > 0.005) {
            r.f.airborne = 1;
            v.tLO = t;
            v.nLO = x[S.N];
            v.VLO = o.Va;
            v.thLO = x[S.THE];
        }
        // referência de altura com catraca (não devolve altura já ganha rumo ao alvo)
        if (r.f.autop != 0 and r.f.flare == 0 and r.f.landed == 0 and sg.landing == 0) {
            if (o.g.hseg > x[S.HR] and h > x[S.HR]) x[S.HR] = @min(h, o.g.hseg) else if (o.g.hseg < x[S.HR] and h < x[S.HR]) x[S.HR] = @max(h, o.g.hseg);
        }
        var switched_on = false;
        if (r.f.airborne != 0 and r.f.autop == 0 and hw >= p.takeoff.ht) {
            r.f.autop = 1;
            x[S.HR] = h;
            switched_on = true;
            syncIntegrators(inst, o.c.de, 1.0);
            v.tHt = t;
            v.nHt = x[S.N];
            v.VHt = o.Va;
            v.gHt = o.gama;
        }
        if (r.f.airborne != 0 and sg.takeoff != 0) v.sink = @max(v.sink, r.h_ground - h); // z da decolagem
        if (r.f.airborne != 0 and r.f.autop == 0) v.hw_min_air = @min(v.hw_min_air, hw);
        if (sg.takeoff != 0) {
            v.hcmin = @min(v.hcmin, o.htail);
            if (o.Va > 4.0) v.ratio_to = @max(v.ratio_to, o.ratioCL);
            v.qpeak_to = @max(v.qpeak_to, @abs(x[S.Q]));
        }
        if (r.f.airborne != 0 and r.f.landed == 0 and contact and sg.landing == 0) v.bounced = 1;
        if (o.Va > 4.0) v.ratio_mission = @max(v.ratio_mission, o.ratioCL);
        v.Ipeak = @max(v.Ipeak, o.pr.Ibat);

        // ---- percurso e eventos ----
        var switched = false;
        if (sg.landing == 0 and r.f.seg < p.n_seg - 1 and o.g.s >= sg.L) {
            if (sg.takeoff != 0) v.E_to = x[S.EN] / 3600.0;
            r.f.seg += 1;
            switched = true;
        }
        if (p.pilot.drop != 0 and r.f.released == 0 and r.f.extracting == 0) { // soltura pedida de fora
            r.f.extracting = 1;
            v.tdrop = t;
            v.ndrop = x[S.N];
            v.hdrop = h;
        }
        if (!switched) {
            for (p.event[0..@intCast(p.n_event)], 0..) |*e, k| {
                if (r.f.ev_done[k] != 0 or r.f.seg != e.seg or o.g.s < e.s) continue;
                if (p.pilot.manual != 0 and e.kind != T.event_gust) continue; // no manual, quem solta é o piloto
                r.f.ev_done[k] = 1;
                if (e.kind == T.event_gust) {
                    r.tg = t;
                    v.tg = t;
                } else if (r.f.released == 0) {
                    r.f.extracting = 1;
                    v.tdrop = t;
                    v.ndrop = x[S.N];
                    v.hdrop = h;
                }
            }
        }
        if (r.f.extracting != 0 and r.f.released == 0 and x[S.SL] >= p.payload.bay) {
            r.f.released = 1;
            v.trel = t;
            const R = vec.rotation(x[S.PHI], x[S.THE], x[S.PSI]);
            const rL = vec.V3{ p.payload.r[0] - x[S.SL], p.payload.r[1], p.payload.r[2] };
            const w = vec.V3{ x[S.P], x[S.Q], x[S.R] };
            const pc = vec.mul(R, rL);
            var vb = vec.V3{ x[S.U], x[S.V], x[S.W] } + vec.cross(w, rL);
            vb[0] -= x[S.SLD];
            const vn = vec.mul(R, vb);
            r.pk = .{ x[S.N] + pc[0], x[S.E] + pc[1], x[S.D] + pc[2], vn[0], vn[1], vn[2] };
            r.f.pk_flying = 1;
        }
        if (r.f.pk_flying != 0) { // carga com paraquedas (Euler explícito, desacoplada)
            const W = atm.wind(&p.env, t, -r.pk[2], r.tg);
            const vr = vec.V3{ r.pk[3] - W[0], r.pk[4] - W[1], r.pk[5] - W[2] };
            const Vv = vec.norm(vr);
            inline for (0..3) |i| {
                const accp = -0.5 * p.env.rho * Vv * p.payload.CdS_chute * vr[i] / p.payload.m + (if (i == 2) L.g0 else 0.0);
                r.pk[3 + i] += accp * p.dt;
                r.pk[i] += r.pk[3 + i] * p.dt;
            }
            if (r.pk[2] >= 0.0) {
                r.f.pk_flying = 0;
                v.pk_n = r.pk[0];
                v.pk_e = r.pk[1];
                v.pk_t = t;
            }
        }
        if (sg.landing != 0 and hw < p.ap.hflare) r.f.flare = 1;
        if (sg.landing != 0 and r.f.landed == 0 and main) {
            r.f.landed = 1;
            v.tTD = t;
            v.nTD = x[S.N];
            v.hgnd_td = hgnd;
        }

        // ---- registro ----
        if (log_due) {
            if (log.len > 0) {
                writeRow(inst, &log[nrows.*], &o);
                nrows.* += 1;
            }
            r.next_log += p.dtlog;
            if (r.next_log < t) r.next_log = t + p.dtlog;
        }

        // ---- paradas ----
        const stop = (p.stop_seg >= 0 and r.f.seg == p.stop_seg and switched) or
            (p.stop_t > 0 and t >= p.stop_t) or (p.stop_autop != 0 and switched_on);
        if (stop) {
            v.stopped = 1;
            status = .stopped;
            break;
        }
        if (r.f.landed != 0 and o.Vg < 0.3) {
            v.nStop = x[S.N];
            v.completed = 1;
            status = .completed;
            break;
        }
        if (p.stop_takeoff != 0 and r.f.autop != 0 and hw >= p.takeoff.h_end) {
            v.completed = 1;
            status = .completed;
            break;
        }
        if (t >= p.tmax) {
            status = .timeout;
            break;
        }
        v.hpmin = @min(v.hpmin, o.hprop);
        // a ponta da pá tocou o chão: o voo falha
        if (p.prop_strike != 0 and o.hprop < 0) {
            v.tprop = t;
            status = .crashed;
            break;
        }
        // abaixo do chão, divergiu ou capotou (tocando o chão com mais de 80° de inclinação)
        if (h < hgnd - 1.0 or !std.math.isFinite(x[S.U]) or !std.math.isFinite(x[S.PHI]) or
            !std.math.isFinite(x[S.THE]) or (contact and @abs(fm.wrap(x[S.PHI])) > 1.4))
        {
            status = .crashed;
            break;
        }
        dyn.rk4(inst.ctx(), t, x, p.dt);
        r.t = t + p.dt;
    }
    v.tend = r.t;
    v.E = x[S.EN] / 3600.0;
    return status;
}
