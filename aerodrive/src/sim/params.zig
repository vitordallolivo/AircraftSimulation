//! Avião (arquivo da GUI) -> parâmetros do núcleo (`types.Params`), em Zig.
//!
//! Porta do caminho da GUI `build_model` -> `ZigTranslator.to_native` -> `calibrate`:
//! faixas das superfícies como painéis (CA a 25 % da corda média da faixa), coeficientes do perfil
//! (Helmbold, perfil fino, efetividade de flape), downwash da asa, dispositivos de ponta, massa seca
//! (base + itens, Steiner), propulsão, trem, tanques, carga, ambiente, decolagem, piloto, percurso e
//! mesas/plataformas. Depois calibra o modelo do piloto pela polar do próprio núcleo e o acelerador
//! de equilíbrio pela trimagem (igual a `manager/calibration.py`).
const std = @import("std");
const core = @import("aerosim");
const model = @import("../model/aircraft.zig");
const airfoil = @import("../model/airfoil.zig");
const sk = @import("../model/skeleton.zig");
const v3 = @import("../math/vec3.zig");
const mission = @import("mission.zig");
const fz = @import("../util/fuzz.zig");

const T = core.types;
const L = core.limits;
const V3 = v3.V3;
const Aircraft = model.Aircraft;
const D2R = std.math.pi / 180.0;
const G0 = 9.80665;

pub const Error = model.Error || airfoil.Error || mission.Error || error{ TooManyPanels, TooManyProps, CoreConfig, Calibration };

/// características estáticas (como `static_characteristics` da GUI)
pub const Info = struct {
    mass: f64 = 0,
    CL0: f64 = 0,
    CLa: f64 = 0,
    CLmax: f64 = 0,
    alpha_stall_deg: f64 = 0,
    Vs: f64 = 0,
    Dtrim: f64 = 0,
};

// ------------------------------------------------------------------ geometria das superfícies
fn sideFactor(s: *const model.Surface) f64 {
    return if (s.symmetric and !s.vertical) 2 else 1;
}

pub fn area(s: *const model.Surface) f64 {
    var buf: [model.limits.sections]model.Section = undefined;
    const ss = model.sortedSections(s, &buf);
    var a: f64 = 0;
    if (ss.len > 1) for (ss[0 .. ss.len - 1], ss[1..]) |p, q| {
        a += 0.5 * (p.chord + q.chord) * (q.y - p.y);
    };
    return a * sideFactor(s);
}

pub fn span(s: *const model.Surface) f64 {
    return model.semispan(s) * sideFactor(s);
}

pub fn mac(s: *const model.Surface) f64 {
    var buf: [model.limits.sections]model.Section = undefined;
    const ss = model.sortedSections(s, &buf);
    var num: f64 = 0;
    var den: f64 = 0;
    if (ss.len > 1) for (ss[0 .. ss.len - 1], ss[1..]) |p, q| {
        const dy = q.y - p.y;
        num += dy * (p.chord * p.chord + p.chord * q.chord + q.chord * q.chord) / 3;
        den += dy * (p.chord + q.chord) / 2;
    };
    return if (den > 0) num / den else 0;
}

fn wing(ac: *const Aircraft) ?*const model.Surface {
    for (ac.surfaces) |*s| if (s.enabled and std.mem.eql(u8, s.role, "wing")) return s;
    return null;
}

/// S, c, b (as referências da GUI)
pub fn references(ac: *const Aircraft) [3]f64 {
    const w = wing(ac);
    const pick = struct {
        fn f(v: ?f64, d: f64) f64 {
            return if (v) |x| (if (x != 0) x else d) else d;
        }
    }.f;
    return .{
        pick(ac.Sref, if (w) |x| area(x) else 1.0),
        pick(ac.cref, if (w) |x| mac(x) else 0.3),
        pick(ac.bref, if (w) |x| span(x) else 1.0),
    };
}

const Coeffs = struct { AR: f64, CLa: f64, CL0: f64, CLmax: f64, CD0: f64, Cmac: f64 };

fn coeffs(s: *const model.Surface) Error!Coeffs {
    const S = area(s);
    const b = span(s);
    const AR = if (S > 0) b * b / S else 5.0;
    const af = s.airfoil;
    var thin: ?[2]f64 = null;
    if (af.alpha0 == null or af.cm_ac == null) {
        var p: airfoil.Profile = .{};
        try airfoil.full(af.name, af.coords, &p);
        if (af.inverted) airfoil.invert(&p);
        thin = airfoil.thinAirfoil(p.slice());
    }
    const CLa = s.CLa orelse airfoil.helmbold(af.cl_alpha, if (AR > 0) AR else 5.0);
    const a0 = af.alpha0 orelse thin.?[0];
    return .{
        .AR = if (AR > 0) AR else 5.0,
        .CLa = CLa,
        .CL0 = s.CL0 orelse -CLa * a0 * D2R,
        .CLmax = s.CLmax orelse 0.9 * af.cl_max,
        .CD0 = s.CD0 orelse af.cd0,
        .Cmac = s.Cmac orelse (af.cm_ac orelse thin.?[1]),
    };
}

/// ε0, dε/dα da asa principal (rad)
fn wingDownwash(ac: *const Aircraft) Error![2]f64 {
    const w = wing(ac) orelse return .{ 0, 0 };
    const co = try coeffs(w);
    const CLw0 = co.CL0 + co.CLa * w.incidence * D2R;
    return .{ 2 * CLw0 / (std.math.pi * co.AR), 2 * co.CLa / (std.math.pi * co.AR) };
}

fn group(role: []const u8) i32 {
    if (std.mem.eql(u8, role, "wing")) return 0;
    if (std.mem.eql(u8, role, "htail")) return 1;
    return 2;
}

const Panels = struct {
    p: *T.Params,
    diag: *model.Diag,

    fn add(self: Panels, sp: T.Surface) Error!void {
        const n: usize = @intCast(self.p.n_surf);
        if (n >= L.max_surfaces) {
            self.diag.set("painéis demais para o núcleo (máximo {d}): menos seções/comandos", .{L.max_surfaces});
            return error.TooManyPanels;
        }
        self.p.surf[n] = sp;
        self.p.n_surf += 1;
    }
};

fn surfacePanels(out: Panels, ac: *const Aircraft, s: *const model.Surface, dw: [2]f64) Error!void {
    const co = try coeffs(s);
    var sbuf: [model.limits.sections * 3]sk.Station = undefined;
    const st = sk.stations(ac, s, &sbuf);
    if (st.len < 2) return;
    const mirror = s.symmetric and !s.vertical;
    const sides: []const f64 = if (mirror) &.{ 1, -1 } else &.{0};
    for (st[0 .. st.len - 1], st[1..]) |a, b| {
        const ds = b.s - a.s;
        if (ds < 1e-6) continue;
        const S = 0.5 * (a.chord + b.chord) * ds;
        const cm = S / ds;
        const mid = v3.scale(v3.add(a.le, b.le), 0.5);
        var inc = 0.5 * (a.twist + b.twist);
        var tau: f64 = 0;
        const ctl = sk.controlAt(s, 0.5 * (a.s + b.s));
        if (ctl) |c| {
            tau = c.tau orelse airfoil.flapEffectiveness(c.chord_frac);
            if (std.mem.eql(u8, c.kind, "flap")) {
                inc += tau * c.deflection;
                tau = 0;
            }
        }
        for (sides) |side| {
            try out.add(.{
                .r = .{ mid[0] - 0.25 * cm, mid[1] * @as(f64, if (side >= 0) 1 else -1), mid[2] },
                .S = S,
                .c = cm,
                .AR = co.AR,
                .e = s.oswald,
                .dihedral = s.dihedral * D2R,
                .incidence = inc * D2R,
                .CLa = co.CLa,
                .CL0 = co.CL0,
                .CLmax = co.CLmax,
                .CD0 = co.CD0,
                .Cmac = co.Cmac,
                .tau = tau,
                .mix = if (ctl) |c| sk.controlMix(c.kind, if (side == 0) 0 else side) else .{ 0, 0, 0 },
                .eta = s.eta,
                .eps0 = if (s.downwash) (if (s.eps0) |x| x * D2R else dw[0]) else 0,
                .depsda = if (s.downwash) (s.depsda orelse dw[1]) else 0,
                .group = group(s.role),
                .vertical = @intFromBool(s.vertical),
                .side = @intFromFloat(side),
                .downwash = @intFromBool(s.downwash),
            });
        }
    }
}

/// winglets, placas e cercas viram painéis (como `universal._devices` + o tradutor)
fn devicePanels(out: Panels, ac: *const Aircraft, s: *const model.Surface) Error!void {
    if (s.vertical) return;
    var sbuf: [model.limits.sections]model.Section = undefined;
    const ss = model.sortedSections(s, &sbuf);
    const pos = model.tailOnBoom(ac, s);
    for (s.devices) |d| {
        if (!d.enabled or d.height <= 0) continue;
        const y = std.math.clamp(d.eta, 0, 1) * model.semispan(s);
        const dih = s.dihedral * D2R;
        const le0: V3 = .{ pos.x - model.sectionAt(ss, y, "x_offset") - d.dx, s.y + y * @cos(dih), pos.z - y * @sin(dih) };
        const c0 = if (d.root_chord > 0) d.root_chord else model.sectionAt(ss, y, "chord");
        const cerca = std.mem.eql(u8, d.kind, "cerca");
        const ct = if (cerca) c0 else c0 * d.taper;
        const cant = d.cant * D2R;
        const sweep = if (cerca) 0.0 else d.sweep * D2R;
        const Part = struct { up: bool, h: f64 };
        const parts: []const Part = if (std.mem.eql(u8, d.kind, "winglet_baixo")) &.{.{ .up = false, .h = d.height }} else if (std.mem.eql(u8, d.kind, "placa")) &.{ .{ .up = true, .h = d.height / 2 }, .{ .up = false, .h = d.height / 2 } } else &.{.{ .up = true, .h = d.height }};
        for (parts) |part| {
            const u: V3 = if (cerca) .{ 0, 0, -1 } else .{ 0, @sin(cant), if (part.up) -@cos(cant) else @cos(cant) };
            const leg_area = 0.5 * (c0 + ct) * part.h;
            const AR = @max(part.h * part.h / @max(leg_area, 1e-9), 0.3);
            const dihedral = std.math.atan2(-u[2], @abs(u[1]));
            const twist = d.toe * @as(f64, if (part.up) 1 else -1);
            const sides: []const f64 = if (s.symmetric) &.{ 1, -1 } else &.{1};
            for (0..3) |i| {
                const ha = part.h * @as(f64, @floatFromInt(i)) / 3.0;
                const hb = part.h * @as(f64, @floatFromInt(i + 1)) / 3.0;
                const ca = c0 + (ha / part.h) * (ct - c0);
                const cb = c0 + (hb / part.h) * (ct - c0);
                const lea = v3.sub(v3.add(le0, v3.scale(u, ha)), .{ ha * @tan(sweep), 0, 0 });
                const leb = v3.sub(v3.add(le0, v3.scale(u, hb)), .{ hb * @tan(sweep), 0, 0 });
                const ds = hb - ha;
                const S = 0.5 * (ca + cb) * ds;
                const cm = S / ds;
                const mid = v3.scale(v3.add(lea, leb), 0.5);
                for (sides) |side| {
                    try out.add(.{
                        .r = .{ mid[0] - 0.25 * cm, mid[1] * @as(f64, if (side >= 0) 1 else -1), mid[2] },
                        .S = S,
                        .c = cm,
                        .AR = AR,
                        .e = d.oswald,
                        .dihedral = dihedral,
                        .incidence = twist * D2R,
                        .CLa = airfoil.helmbold(d.cl_alpha, AR),
                        .CL0 = 0,
                        .CLmax = 1,
                        .CD0 = d.cd0,
                        .Cmac = 0,
                        .group = 2,
                        .side = @intFromFloat(side),
                    });
                }
            }
        }
    }
}

// ------------------------------------------------------------------ massa seca (massprops.py)
const Point = struct { m: f64, r: V3 };

pub const DryMass = struct { m: f64, cg: V3, I: v3.M3 };

pub fn dryMass(ac: *const Aircraft) DryMass {
    var items: [64]Point = undefined;
    var n: usize = 0;
    const push = struct {
        fn f(it: *[64]Point, k: *usize, m: f64, r: V3) void {
            if (k.* < it.len) {
                it[k.*] = .{ .m = m, .r = r };
                k.* += 1;
            }
        }
    }.f;
    const mm = ac.mass;
    for (mm.items) |it| push(&items, &n, it.mass, .{ it.x, it.y, it.z });
    if (ac.ballast.enabled and ac.ballast.mass > 0) push(&items, &n, ac.ballast.mass, .{ ac.ballast.x, ac.ballast.y, ac.ballast.z });
    if (mm.include_propulsion) for (ac.propulsion) |u| {
        if (!u.enabled) continue;
        const p: V3 = .{ u.x, u.y, u.z };
        const k: f64 = if (u.x < 0) 1 else -1;
        push(&items, &n, u.motor.mass, v3.add(p, .{ k * 0.06, 0, 0 }));
        push(&items, &n, u.propeller.mass, p);
        push(&items, &n, u.battery.mass, v3.add(p, .{ k * 0.25, 0, 0 }));
    };
    if (mm.include_structure) {
        for (ac.surfaces) |*s| if (s.enabled and s.mass > 0) {
            const pos = model.tailOnBoom(ac, s);
            const mc = mac(s);
            push(&items, &n, s.mass, .{ pos.x - 0.4 * (if (mc != 0) mc else 0.2), s.y, pos.z });
        };
        const f = ac.fuselage;
        if (f.enabled and f.mass > 0) push(&items, &n, f.mass, .{ f.x_nose - 0.45 * f.length, 0, f.z });
        for (ac.allBooms()) |b| if (b.enabled and b.mass > 0) push(&items, &n, b.mass, b.middle());
    }
    const m0 = mm.base_mass;
    const cg0: V3 = mm.base_cg;
    var M = m0;
    var mr = v3.scale(cg0, m0);
    for (items[0..n]) |it| {
        M += it.m;
        mr = v3.add(mr, v3.scale(it.r, it.m));
    }
    const cg = v3.scale(mr, 1 / M);
    var I: v3.M3 = .{ .{ mm.Ixx, 0, -mm.Ixz }, .{ 0, mm.Iyy, 0 }, .{ -mm.Ixz, 0, mm.Izz } };
    const steiner = struct {
        fn f(Ii: *v3.M3, mk: f64, r: V3, c: V3) void {
            const d = v3.sub(r, c);
            const dd = v3.dot(d, d);
            for (0..3) |i| for (0..3) |j| {
                Ii[i][j] += mk * ((if (i == j) dd else 0) - d[i] * d[j]);
            };
        }
    }.f;
    steiner(&I, m0, cg0, cg);
    for (items[0..n]) |it| steiner(&I, it.m, it.r, cg);
    return .{ .m = M, .cg = cg, .I = I };
}

// ------------------------------------------------------------------ montagem
const poly_vars = [_][]const u8{ "none", "V", "throttle", "h", "rho", "const" };

fn polyVar(name: []const u8) i32 {
    for (poly_vars, 0..) |v, i| if (std.mem.eql(u8, v, name)) return @intCast(i);
    return T.pvar_none;
}

/// escreve os parâmetros do núcleo (sem calibrar)
pub fn fill(ac: *const Aircraft, p: *T.Params, diag: *model.Diag) Error!void {
    try model.validate(ac, diag);
    p.* = .{};
    const ref = references(ac);
    const dm = dryMass(ac);
    if (!(dm.m > 0) or !v3.finite(dm.cg)) {
        diag.set("massa seca inválida", .{});
        return error.NotPositive;
    }
    p.m_dry = dm.m;
    p.Ixx = dm.I[0][0];
    p.Iyy = dm.I[1][1];
    p.Izz = dm.I[2][2];
    p.Ixz = -dm.I[0][2];
    p.r_dry = dm.cg;
    p.Sref = ref[0];
    p.cref = ref[1];
    p.bref = ref[2];
    p.Mst = ac.sim.Mst;
    const f = ac.fuselage;
    p.fus_CDS = if (f.enabled) f.CDS else 0;
    for (ac.allBooms()) |b| if (b.enabled) {
        p.fus_CDS += 0.006 * std.math.pi * b.diameter * b.length; // atrito dos tubos
    };
    p.fus_Cma = if (f.enabled) f.Cma else 0;
    p.fus_Cnb = if (f.enabled) f.Cnb else 0;
    p.fus_CYb = if (f.enabled) f.CYb else 0;
    p.fus_r = f.aero_point orelse .{ f.x_nose - 0.4 * f.length, 0, f.z };

    const dw = try wingDownwash(ac);
    const out: Panels = .{ .p = p, .diag = diag };
    for (ac.surfaces) |*s| {
        if (!s.enabled or s.sections.len < 2) continue;
        surfacePanels(out, ac, s, dw) catch |e| {
            if (e == error.InvalidAirfoil or e == error.TooManyPoints) diag.set("{s}: perfil inválido", .{s.name});
            return e;
        };
        try devicePanels(out, ac, s);
    }

    var units: usize = 0;
    for (ac.propulsion) |u| units += @intFromBool(u.enabled);
    const K: f64 = @floatFromInt(@max(units, 1));
    if (units > L.max_props) {
        diag.set("motores demais (máximo {d})", .{L.max_props});
        return error.TooManyProps;
    }
    for (ac.propulsion) |u| {
        if (!u.enabled) continue;
        const pr = u.propeller;
        const tp = u.thrust_poly;
        var pu: T.PropUnit = .{
            .model = if (std.mem.eql(u8, u.thrust_model, "poly")) T.prop_poly else T.prop_motor,
            .poly_x = polyVar(tp.x_var),
            .poly_y = polyVar(tp.y_var),
            .poly_gain = tp.gain,
            .poly_rho_exp = tp.rho_exp,
            .poly_rho0 = tp.rho0,
            .poly_xmax = tp.xmax,
            .poly_ymax = tp.ymax,
            .poly_xc = tp.x_const,
            .poly_yc = tp.y_const,
            .r = .{ u.x, u.y, u.z },
            .tilt = u.tilt * D2R,
            .toe = u.toe * D2R,
            .sense = u.sense,
            .D = pr.D,
            .Ip = pr.Ip,
            .Jm = u.motor.Jm,
            .Kv = u.motor.Kv,
            .Rm = u.motor.Rm,
            .B = u.motor.B,
            .tauc = u.motor.tauc,
            .Imax = u.motor.Imax,
            .Voc = u.battery.voc(),
            .Rint = u.battery.Rint * (if (ac.shared_battery) K else 1),
            .yaw_mix = u.yaw_mix,
        };
        for (tp.coefs[0..@min(tp.coefs.len, pu.poly.len)], 0..) |cf, i| pu.poly[i] = cf;
        const np_ = @min(pr.J.len, pr.CT.len, pr.CP.len, L.max_prop_pts);
        for (0..np_) |i| {
            pu.J[i] = pr.J[i];
            pu.CT[i] = pr.CT[i];
            pu.CP[i] = pr.CP[i];
        }
        pu.n_pts = @intCast(np_);
        p.prop[@intCast(p.n_prop)] = pu;
        p.n_prop += 1;
    }

    const g = ac.gear;
    var legs: [model.limits.gear_legs]sk.Leg = undefined;
    const nl = sk.gearLegs(g, &legs);
    if (nl > L.max_gear) {
        diag.set("trem: {d} pernas (máximo {d})", .{ nl, L.max_gear });
        return error.TooMany;
    }
    const custom = std.mem.eql(u8, g.layout, "custom");
    for (legs[0..nl], 0..) |q, i| {
        // pernas padrão: 0 bequilha, 1-2 principais, 3 patim (igual a LandingGear.legs)
        const kind: i32, const k: f64, const cc: f64 = if (custom) .{
            if (std.mem.eql(u8, g.custom[i].kind, "steer")) T.gear_steer else if (std.mem.eql(u8, g.custom[i].kind, "skid")) T.gear_skid else T.gear_main,
            g.custom[i].k,
            g.custom[i].c,
        } else switch (i) {
            0 => .{ T.gear_steer, g.steer_k, g.steer_c },
            1, 2 => .{ T.gear_main, g.main_k, g.main_c },
            else => .{ T.gear_skid, g.skid_k, g.skid_c },
        };
        p.gear[i] = .{ .r = .{ q.x, q.y, q.z }, .k = k, .c = cc, .kind = kind };
    }
    p.n_gear = @intCast(nl);

    for (ac.tanks, 0..) |t, i| {
        p.tank[i] = .{ .r = .{ t.x, t.y, t.z }, .side = t.side, .fill = t.fill(), .rho = t.rho, .zeta = t.zeta, .shape = if (std.mem.eql(u8, t.shape, "square")) T.tank_square else T.tank_cylinder };
    }
    p.n_tank = @intCast(ac.tanks.len);
    p.slosh_on = @intFromBool(ac.sim.slosh);
    p.mu_roll = g.mu_roll;
    p.mu_lat = g.mu_lat;
    p.mu_brake = g.mu_brake;
    p.mu_skid = g.mu_skid;
    p.mu_landing = g.mu_landing;
    const P = ac.payload;
    p.payload = .{ .enabled = @intFromBool(P.enabled), .m = P.mass, .r = .{ P.x, P.y, P.z }, .bay = P.bay, .Fext_g = P.Fext_g, .mu_b = P.mu_b, .CdS_chute = P.CdS_chute };
    const e = ac.environment;
    p.env = .{ .rho = e.rho, .Vw10 = e.wind_speed, .wind_from = e.wind_from * D2R, .wind_elev = e.wind_elev * D2R, .h_ref = e.h_ref, .gust_T = e.gust_T, .gust_on = @intFromBool(e.gust) };
    for (e.gust_U[0..@min(e.gust_U.len, 3)], 0..) |x, i| p.env.gust_U[i] = x;
    const to = ac.takeoff;
    p.takeoff = .{ .VR = to.VR, .sR = to.sR, .de0 = to.de0 * D2R, .de1 = to.de1 * D2R, .rate_de = to.rate_de * D2R, .ht = to.ht, .rate_thr = to.rate_thr, .h_end = to.h_end };
    inline for (@typeInfo(T.Autopilot).@"struct".fields) |fld| {
        const val = @field(ac.autopilot, fld.name);
        const angle = comptime for ([_][]const u8{ "alpha_max", "chi_inf", "phimax", "pmax_cmd", "de_max", "da_max", "dr_max" }) |k| {
            if (std.mem.eql(u8, k, fld.name)) break true;
        } else false;
        @field(p.ap, fld.name) = if (angle) val * D2R else val;
    }
    p.dt = ac.sim.dt;
    p.tmax = ac.sim.tmax;
    p.dtlog = ac.sim.dtlog;
    const ns = try mission.segments(&ac.mission, &p.seg, diag);
    p.n_seg = @intCast(ns);
    p.n_event = @intCast(try mission.events(&ac.mission, &p.event, diag));
    p.n_pad = @intCast(mission.pads(&ac.airfield, p.seg[0..ns], &p.pads));
}

/// parâmetros + configuração do núcleo + calibração do piloto (como `prepare` da GUI)
pub fn setup(ac: *const Aircraft, inst: *core.runner.Instance, diag: *model.Diag) Error!Info {
    try fill(ac, &inst.p, diag);
    core.runner.configure(inst) catch |e| {
        diag.set("o núcleo recusou a configuração ({s})", .{@errorName(e)});
        return error.CoreConfig;
    };
    var info = staticCharacteristics(inst, ac);
    if (ac.autopilot.auto_calibrate) {
        if (!std.math.isFinite(info.CL0) or !std.math.isFinite(info.CLa) or !(info.CLa > 0)) {
            diag.set("calibração do piloto falhou (polar sem inclinação)", .{});
            return error.Calibration;
        }
        inst.p.ap.CL0 = info.CL0;
        inst.p.ap.CLa = info.CLa;
        var Vc: f64 = 15;
        if (inst.p.n_seg > 0) {
            Vc = 0;
            for (inst.p.seg[0..@intCast(inst.p.n_seg)]) |sg| Vc = @max(Vc, sg.V1);
        }
        const tp = core.trim.solve(core.trim.Ctx.init(&inst.p, &inst.r.f), T.trim_level, Vc, 1.0, null);
        if (tp.ok != 0 and tp.thr > 0.05 and tp.thr < 1.0) inst.p.ap.Dtrim = tp.thr;
        // ganhos das malhas internas pelo modelo linear do próprio avião (iguais para qualquer um)
        _ = core.autotune.tune(&inst.p, &inst.r.f, Vc);
        core.runner.configure(inst) catch return error.CoreConfig;
    }
    info.Dtrim = inst.p.ap.Dtrim;
    return info;
}

/// polar −6°..30° a 12 m/s; ajuste linear de −2° a 8° (igual à GUI)
pub fn staticCharacteristics(inst: *core.runner.Instance, ac: *const Aircraft) Info {
    const tc = core.trim.Ctx.init(&inst.p, &inst.r.f);
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    var n: f64 = 0;
    var best: f64 = -1e9;
    var a_best: f64 = 0;
    var i: usize = 0;
    while (i <= 144) : (i += 1) {
        const a = (-6.0 + 0.25 * @as(f64, @floatFromInt(i))) * D2R;
        const co = core.aero.coeffs(&inst.p, 12.0, a, 0, tc.rcg, .{ 0, 0, 0 });
        if (a >= -2 * D2R - 1e-12 and a <= 8 * D2R + 1e-12) {
            sx += a;
            sy += co.CL;
            sxx += a * a;
            sxy += a * co.CL;
            n += 1;
        }
        if (co.CL > best) {
            best = co.CL;
            a_best = a;
        }
    }
    const CLa = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    const CL0 = (sy - CLa * sx) / n;
    const S = references(ac)[0];
    return .{
        .mass = tc.m,
        .CL0 = CL0,
        .CLa = CLa,
        .CLmax = best,
        .alpha_stall_deg = a_best / D2R,
        .Vs = if (best > 0) @sqrt(2 * tc.m * G0 / (ac.environment.rho * S * best)) else std.math.nan(f64),
    };
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

fn loadExample(name: []const u8, d: *model.Diag) !model.Loaded {
    const path = try std.fmt.allocPrint(testing.allocator, "../data/aircraft/{s}.json", .{name});
    defer testing.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 24));
    defer testing.allocator.free(bytes);
    return model.parse(testing.allocator, bytes, d);
}

const Ref = struct { name: []const u8, n_surf: i32, m: f64, Ixx: f64, S: f64, c: f64, b: f64, CL0: f64, CLa: f64, Vs: f64, Dtrim: f64 };

// valores da GUI (aerosim: `native_spec` + `calibrate`) para os exemplos de data/aircraft
const refs = [_]Ref{
    .{ .name = "Convencional_original", .n_surf = 7, .m = 8.39, .Ixx = 0.9, .S = 1.0, .c = 0.4, .b = 2.5, .CL0 = 0.3978557237044486, .CLa = 4.747129183532616, .Vs = 10.971265478835655, .Dtrim = 0.9044188624346622 },
    .{ .name = "Asa_voadora", .n_surf = 10, .m = 3.0, .Ixx = 0.25, .S = 0.6605, .c = 0.3432904365379763, .b = 2.0, .CL0 = 0.18990023335521117, .CLa = 4.39425402434299, .Vs = 7.988838222100006, .Dtrim = 0.5965329643547685 },
    .{ .name = "Bimotor_convencional_tubo_cauda_em_V", .n_surf = 12, .m = 6.3, .Ixx = 0.9, .S = 0.8568, .c = 0.3091764705882352, .b = 2.8, .CL0 = 0.4964499816909635, .CLa = 5.09252394757893, .Vs = 9.681856755277657, .Dtrim = 0.55 },
};

test "exemplos: mesmos parâmetros e calibração da GUI" {
    for (refs) |r| {
        var d: model.Diag = .{};
        var l = try loadExample(r.name, &d);
        defer l.deinit();
        const inst = try testing.allocator.create(core.runner.Instance);
        defer testing.allocator.destroy(inst);
        inst.* = .{};
        const info = try setup(&l.ac, inst, &d);
        const p = &inst.p;
        errdefer std.debug.print("avião: {s}\n", .{r.name});
        try testing.expectEqual(r.n_surf, p.n_surf);
        try testing.expectApproxEqAbs(r.m, p.m_dry, 1e-9);
        try testing.expectApproxEqAbs(r.Ixx, p.Ixx, 1e-9);
        try testing.expectApproxEqAbs(r.S, p.Sref, 1e-9);
        try testing.expectApproxEqAbs(r.c, p.cref, 1e-9);
        try testing.expectApproxEqAbs(r.b, p.bref, 1e-9);
        try testing.expectApproxEqAbs(r.CL0, info.CL0, 1e-6);
        try testing.expectApproxEqAbs(r.CLa, info.CLa, 1e-6);
        try testing.expectApproxEqAbs(r.Vs, info.Vs, 1e-6);
        try testing.expectApproxEqAbs(r.Dtrim, info.Dtrim, 1e-6);
    }
}

test "tubos: o formato novo (booms, cauda já no lugar) voa igual ao antigo (boom único)" {
    var d: model.Diag = .{};
    var l = try loadExample("Bimotor_convencional_tubo_cauda_em_V", &d);
    defer l.deinit();
    const old = l.ac;
    var surf: [8]model.Surface = undefined;
    for (old.surfaces, 0..) |*s, i| {
        surf[i] = s.*;
        const pos = model.tailOnBoom(&old, s);
        surf[i].x = pos.x;
        surf[i].z = pos.z;
    }
    var nb = old.boom;
    nb.attach_tail = false;
    const booms = [_]model.Boom{nb};
    var new = old;
    new.surfaces = surf[0..old.surfaces.len];
    new.boom = .{};
    new.booms = &booms;
    const a = try testing.allocator.create(core.runner.Instance);
    defer testing.allocator.destroy(a);
    const b = try testing.allocator.create(core.runner.Instance);
    defer testing.allocator.destroy(b);
    a.* = .{};
    b.* = .{};
    const ia = try setup(&old, a, &d);
    const ib = try setup(&new, b, &d);
    try testing.expectApproxEqAbs(a.p.fus_CDS, b.p.fus_CDS, 1e-12);
    try testing.expectApproxEqAbs(a.p.m_dry, b.p.m_dry, 1e-12);
    try testing.expectApproxEqAbs(a.p.Iyy, b.p.Iyy, 1e-12);
    try testing.expectApproxEqAbs(ia.Vs, ib.Vs, 1e-9);
    try testing.expectApproxEqAbs(ia.Dtrim, ib.Dtrim, 1e-9);
    try testing.expectApproxEqAbs(ia.CLa, ib.CLa, 1e-9);
}

test "Convencional: painéis iguais aos do tradutor da GUI" {
    // (x, y, S, C_Lα, C_L0, τ, mix) de cada painel, na ordem do tradutor Python
    const P = struct { x: f64, y: f64, S: f64, CLa: f64, CL0: f64, tau: f64, mix: [3]f64 };
    const want = [_]P{
        .{ .x = 0.035, .y = 0.374486, .S = 0.3, .CLa = 4.387744, .CL0 = 0.3, .tau = 0, .mix = .{ 0, 0, 0 } },
        .{ .x = 0.035, .y = -0.374486, .S = 0.3, .CLa = 4.387744, .CL0 = 0.3, .tau = 0, .mix = .{ 0, 0, 0 } },
        .{ .x = 0.035, .y = 0.99863, .S = 0.2, .CLa = 4.387744, .CL0 = 0.3, .tau = 0.5, .mix = .{ 0, -1, 0 } },
        .{ .x = 0.035, .y = -0.99863, .S = 0.2, .CLa = 4.387744, .CL0 = 0.3, .tau = 0.5, .mix = .{ 0, 1, 0 } },
        .{ .x = -1.05, .y = 0.223607, .S = 0.1, .CLa = 3.747838, .CL0 = 0, .tau = 0.5, .mix = .{ 1, 0, 0 } },
        .{ .x = -1.05, .y = -0.223607, .S = 0.1, .CLa = 3.747838, .CL0 = 0, .tau = 0.5, .mix = .{ 1, 0, 0 } },
        .{ .x = -1.1, .y = 0, .S = 0.12, .CLa = 2.172507, .CL0 = 0, .tau = 0.5, .mix = .{ 0, 0, -1 } },
    };
    var d: model.Diag = .{};
    var l = try loadExample("Convencional_original", &d);
    defer l.deinit();
    var p: T.Params = undefined;
    try fill(&l.ac, &p, &d);
    for (want, p.surf[0..want.len]) |w, s| {
        try testing.expectApproxEqAbs(w.x, s.r[0], 1e-6);
        try testing.expectApproxEqAbs(w.y, s.r[1], 1e-6);
        try testing.expectApproxEqAbs(w.S, s.S, 1e-6);
        try testing.expectApproxEqAbs(w.CLa, s.CLa, 1e-6);
        try testing.expectApproxEqAbs(w.CL0, s.CL0, 1e-6);
        try testing.expectApproxEqAbs(w.tau, s.tau, 1e-6);
        for (w.mix, s.mix) |a, b| try testing.expectEqual(a, b + 0.0);
    }
}

fn fuzzParams(_: void, src: *fz.Src) anyerror!void {
    // avião de exemplo com números trocados: dá erro previsto ou parâmetros finitos que o núcleo aceita
    var d: model.Diag = .{};
    const names = [_][]const u8{ "Convencional_original", "Asa_voadora", "Bimotor_convencional_tubo_cauda_em_V", "Convencional_decola_da_mesa_pousa_na_plataforma" };
    var l = try loadExample(names[src.index(names.len)], &d);
    defer l.deinit();
    var ac = l.ac;
    ac.mass.base_mass = src.mostly(0.5, 30);
    ac.mass.Ixx = src.mostly(0.01, 5);
    ac.environment.wind_speed = src.mostly(0, 15);
    ac.sim.dt = src.mostly(1e-4, 5e-3);
    ac.Sref = if (src.boolean()) src.mostly(0.1, 3) else null;
    var p: T.Params = undefined;
    fill(&ac, &p, &d) catch {
        try testing.expect(d.len > 0);
        return;
    };
    try testing.expect(std.math.isFinite(p.m_dry) and std.math.isFinite(p.Sref));
    for (p.surf[0..@intCast(p.n_surf)]) |s| try testing.expect(std.math.isFinite(s.S) and std.math.isFinite(s.CLa));
}

test "fuzz: parâmetros do núcleo" {
    try fz.checkScaled({}, fuzzParams, .{}, 4); // cada caso lê um arquivo de exemplo
}
