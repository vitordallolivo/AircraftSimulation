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
const methods = @import("methods.zig");
const modifiers = @import("modifiers.zig");
const fz = @import("../util/fuzz.zig");

const types = core.types;
const limits = core.limits;
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
    /// margem estática, −dC_m/dC_L na mesma faixa do ajuste (−2° a 8°)
    static_margin: f64 = 0,
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

/// x (corpo) do bordo de ataque da CMA da asa, onde o CG fica em 0 % da CMA: a CMA está na posição da envergadura
/// ∫c·y dy / ∫c dy (como `SurfaceModel.mac()["x_le"]` do Python, `aerosim/model/universal.py`)
pub fn macLeadingEdge(ac: *const Aircraft) f64 {
    const w = wing(ac) orelse return 0;
    var buf: [model.limits.sections]model.Section = undefined;
    const ss = model.sortedSections(w, &buf);
    var den: f64 = 0;
    var moment: f64 = 0;
    if (ss.len > 1) for (ss[0 .. ss.len - 1], ss[1..]) |p, q| {
        const dy = q.y - p.y;
        den += dy * (p.chord + q.chord) / 2;
        moment += dy * (p.chord * (2 * p.y + q.y) + q.chord * (p.y + 2 * q.y)) / 6;
    };
    const y_mac = if (den > 0) moment / den else 0;
    return model.tailOnBoom(ac, w).x - model.sectionAt(ss, y_mac, "x_offset");
}

fn wing(ac: *const Aircraft) ?*const model.Surface {
    return firstSurface(ac, "wing");
}

/// a primeira superfície ligada com o papel `role` ("wing", "htail", "vtail"), como `AircraftModel.wing`/`htail`
pub fn firstSurface(ac: *const Aircraft, role: []const u8) ?*const model.Surface {
    for (ac.surfaces) |*s| if (s.enabled and std.mem.eql(u8, s.role, role)) return s;
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

/// os coeficientes da superfície inteira (os do `SurfaceModel` da GUI): alongamento, C_Lα (1/rad), C_L0, C_Lmáx,
/// C_D0 e C_m,ac, com a média por área quando as seções têm perfis diferentes
pub const Coeffs = struct { AR: f64, CLa: f64, CL0: f64, CLmax: f64, CD0: f64, Cmac: f64 };

/// (c_lα 1/rad, α_L0 graus, c_l máx, c_d0, c_m,ac) do perfil — `_props2d` da GUI
pub const P2 = [5]f64;

/// os números 2D do perfil (α_L0 e c_m,ac pela teoria do perfil fino quando o perfil não os traz)
pub fn props2d(af: model.Airfoil) Error!P2 {
    var thin: ?[2]f64 = null;
    if (af.alpha0 == null or af.cm_ac == null) {
        var p: airfoil.Profile = .{};
        try airfoil.full(af.name, af.coords, &p);
        if (af.inverted) airfoil.invert(&p);
        thin = airfoil.thinAirfoil(p.slice());
    }
    return .{ af.cl_alpha, af.alpha0 orelse thin.?[0], af.cl_max, af.cd0, af.cm_ac orelse thin.?[1] };
}

/// 2D → 3D (Helmbold com o alongamento da superfície); as sobrescritas da superfície mandam
fn coeffsFrom(s: *const model.Surface, AR: f64, p: P2) Coeffs {
    const CLa = s.CLa orelse airfoil.helmbold(p[0], AR);
    return .{
        .AR = AR,
        .CLa = CLa,
        .CL0 = s.CL0 orelse -CLa * p[1] * D2R,
        .CLmax = s.CLmax orelse 0.9 * p[2],
        .CD0 = s.CD0 orelse p[3],
        .Cmac = s.Cmac orelse p[4],
    };
}

fn aspect(s: *const model.Surface) f64 {
    const S = area(s);
    const b = span(s);
    const AR = if (S > 0) b * b / S else 5.0;
    return if (AR > 0) AR else 5.0;
}

const SecProps = struct { y: f64, p: P2 };

/// propriedades 2D de cada seção, em ordem de y (perfil por seção)
fn sectionProps(s: *const model.Surface, out: *[model.limits.sections]SecProps) Error![]SecProps {
    var sbuf: [model.limits.sections]model.Section = undefined;
    const ss = model.sortedSections(s, &sbuf);
    for (ss, 0..) |q, k| out[k] = .{ .y = q.y, .p = try props2d(q.airfoil orelse s.airfoil) };
    return out[0..ss.len];
}

/// interpolação linear entre as seções (igual a `_props_at`)
fn propsAt(sp: []const SecProps, y: f64) P2 {
    if (y <= sp[0].y) return sp[0].p;
    for (sp[0 .. sp.len - 1], sp[1..]) |a, b| {
        if (y <= b.y) {
            const f = if (b.y > a.y) (y - a.y) / (b.y - a.y) else 0.0;
            var r: P2 = undefined;
            for (0..5) |i| r[i] = a.p[i] + f * (b.p[i] - a.p[i]);
            return r;
        }
    }
    return sp[sp.len - 1].p;
}

/// os coeficientes da superfície `s` (ver `Coeffs`)
pub fn coeffs(s: *const model.Surface) Error!Coeffs {
    const AR = aspect(s);
    if (!model.mixedAirfoils(s) or s.sections.len < 2) return coeffsFrom(s, AR, try props2d(s.airfoil));
    // perfil por seção: média pela área de cada trecho entre seções (no meio do trecho), como `_coeffs`
    var pbuf: [model.limits.sections]SecProps = undefined;
    const sp = try sectionProps(s, &pbuf);
    var acc = [5]f64{ 0, 0, 0, 0, 0 };
    var At: f64 = 0;
    for (sp[0 .. sp.len - 1], sp[1..], 0..) |q0, q1, k| {
        var sbuf: [model.limits.sections]model.Section = undefined;
        const ss = model.sortedSections(s, &sbuf);
        const A = 0.5 * (ss[k].chord + ss[k + 1].chord) * (q1.y - q0.y);
        const c = coeffsFrom(s, AR, propsAt(sp, 0.5 * (q0.y + q1.y)));
        const v = [5]f64{ c.CLa, c.CL0, c.CLmax, c.CD0, c.Cmac };
        for (0..5) |i| acc[i] += v[i] * A;
        At += A;
    }
    if (At <= 0) return coeffsFrom(s, AR, sp[0].p);
    return .{ .AR = AR, .CLa = acc[0] / At, .CL0 = acc[1] / At, .CLmax = acc[2] / At, .CD0 = acc[3] / At, .Cmac = acc[4] / At };
}

/// ε0, dε/dα da asa principal (rad)
pub fn wingDownwash(ac: *const Aircraft) Error![2]f64 {
    const w = wing(ac) orelse return .{ 0, 0 };
    const co = try coeffs(w);
    const CLw0 = co.CL0 + co.CLa * w.incidence * D2R;
    return .{ 2 * CLw0 / (std.math.pi * co.AR), 2 * co.CLa / (std.math.pi * co.AR) };
}

fn group(role: []const u8) limits.Group {
    if (std.mem.eql(u8, role, "wing")) return .wing;
    if (std.mem.eql(u8, role, "htail")) return .htail;
    return .vtail;
}

const Panels = struct {
    params: *types.Params,
    diag: *model.Diag,

    fn add(self: Panels, sp: types.Surface) Error!void {
        const n: usize = @intCast(self.params.n_surf);
        if (n >= limits.max_surfaces) {
            self.diag.set("painéis demais para o núcleo (máximo {d}): menos seções/comandos", .{limits.max_surfaces});
            return error.TooManyPanels;
        }
        self.params.surf[n] = sp;
        self.params.n_surf += 1;
    }
};

fn surfacePanels(out: Panels, ac: *const Aircraft, s: *const model.Surface, owner: usize, dw: [2]f64) Error!void {
    const co = try coeffs(s);
    var sbuf: [model.limits.sections * 3]sk.Station = undefined;
    const st = sk.stations(ac, s, &sbuf);
    if (st.len < 2) return;
    const mirror = s.symmetric and !s.vertical;
    const sides: []const f64 = if (mirror) &.{ 1, -1 } else &.{0};
    const mixed = model.mixedAirfoils(s) and s.sections.len > 1;
    var pbuf: [model.limits.sections]SecProps = undefined;
    const sp = if (mixed) try sectionProps(s, &pbuf) else pbuf[0..0];
    for (st[0 .. st.len - 1], st[1..]) |a, b| {
        const ds = b.s - a.s;
        if (ds < 1e-6) continue;
        const cs = if (mixed) coeffsFrom(s, co.AR, propsAt(sp, 0.5 * (a.s + b.s))) else co; // perfil por seção
        const S = 0.5 * (a.chord + b.chord) * ds;
        const cm = S / ds;
        const mid = v3.scale(v3.add(a.le, b.le), 0.5);
        var inc = 0.5 * (a.twist + b.twist);
        var tau: f64 = 0;
        const ctl = sk.controlAt(s, 0.5 * (a.s + b.s));
        if (ctl) |c| {
            tau = c.tau orelse airfoil.flapEffectiveness(c.chord_frac);
            inc += tau * c.deflection; // deflexão fixa (flape, flaperon baixado)
            if (std.mem.eql(u8, c.role(), "flap")) tau = 0;
        }
        for (sides) |side| {
            const sign: f64 = if (side >= 0) 1 else -1;
            try out.add(.{
                .r = .{ mid[0] - 0.25 * cm, mid[1] * sign, mid[2] },
                // 1/4 de corda nas bordas: os nós da ferradura da linha sustentadora (Phillips e Snyder 2000), como
                // `surface_panels` do tradutor em Python; as faixas não leem
                .qa = .{ a.le[0] - 0.25 * a.chord, a.le[1] * sign, a.le[2] },
                .qb = .{ b.le[0] - 0.25 * b.chord, b.le[1] * sign, b.le[2] },
                .S = S,
                .c = cm,
                .AR = co.AR,
                .e = s.oswald,
                .dihedral = s.dihedral * D2R,
                .incidence = inc * D2R,
                .CLa = cs.CLa,
                .CL0 = cs.CL0,
                .CLmax = cs.CLmax,
                .CD0 = cs.CD0,
                .Cmac = cs.Cmac,
                .tau = tau,
                .mix = if (ctl) |c| sk.controlMix(c, side) else .{ 0, 0, 0 },
                .eta = s.eta,
                .eps0 = if (s.downwash) (if (s.eps0) |x| x * D2R else dw[0]) else 0,
                .depsda = if (s.downwash) (s.depsda orelse dw[1]) else 0,
                .group = group(s.role),
                .owner = @intCast(owner), // a superfície do painel (interferência entre asas)
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
                    const sign: f64 = if (side >= 0) 1 else -1;
                    try out.add(.{
                        .r = .{ mid[0] - 0.25 * cm, mid[1] * sign, mid[2] },
                        .qa = .{ lea[0] - 0.25 * ca, lea[1] * sign, lea[2] },
                        .qb = .{ leb[0] - 0.25 * cb, leb[1] * sign, leb[2] },
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
                        .group = .vtail,
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

/// raio de giração da meia superfície em torno do plano de simetria, com densidade por área constante:
/// r² = ∫ (y_0 + η)² c(η) dη / ∫ c(η) dη, corda linear entre as seções, trapézios de 33 pontos por trecho
/// (o mesmo de massprops.py `_half_gyration`); null sem seções ou sem área
fn halfGyration(s: *const model.Surface) ?f64 {
    if (s.sections.len < 2) return null;
    var A: f64 = 0;
    var J: f64 = 0;
    for (s.sections[0 .. s.sections.len - 1], s.sections[1..]) |a, b| {
        var e0 = a.y;
        var c0 = a.chord;
        for (1..33) |k| {
            const t = @as(f64, @floatFromInt(k)) / 32.0;
            const e1 = a.y + t * (b.y - a.y);
            const c1 = a.chord + t * (b.chord - a.chord);
            const h = e1 - e0;
            A += 0.5 * h * (c0 + c1);
            J += 0.5 * h * ((s.y + e0) * (s.y + e0) * c0 + (s.y + e1) * (s.y + e1) * c1);
            e0 = e1;
            c0 = c1;
        }
    }
    if (!(A > 0)) return null;
    return @sqrt(J / A);
}

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
            const x = pos.x - 0.4 * (if (mc != 0) mc else 0.2);
            const r = if (s.symmetric and !s.vertical) halfGyration(s) else null;
            if (r) |ry| { // cada meia asa com a metade da massa, no raio de giração dela (rolamento)
                push(&items, &n, 0.5 * s.mass, .{ x, ry, pos.z });
                push(&items, &n, 0.5 * s.mass, .{ x, -ry, pos.z });
            } else push(&items, &n, s.mass, .{ x, s.y, pos.z });
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

fn polyVar(name: []const u8) types.PolyVariable {
    for (poly_vars, 0..) |v, i| if (std.mem.eql(u8, v, name)) return @enumFromInt(i);
    return .none;
}

/// escreve os parâmetros do núcleo (sem calibrar)
pub fn fill(ac: *const Aircraft, params: *types.Params, diag: *model.Diag) Error!void {
    try model.validate(ac, diag);
    params.* = .{};
    const reference = references(ac);
    const dry = dryMass(ac);
    if (!(dry.m > 0) or !v3.finite(dry.cg)) {
        diag.set("massa seca inválida", .{});
        return error.NotPositive;
    }
    params.m_dry = dry.m;
    params.Ixx = dry.I[0][0];
    params.Iyy = dry.I[1][1];
    params.Izz = dry.I[2][2];
    params.Ixz = -dry.I[0][2];
    params.r_dry = dry.cg;
    params.Sref = reference[0];
    params.cref = reference[1];
    params.bref = reference[2];
    params.Mst = ac.sim.Mst;
    const fuselage = ac.fuselage;
    params.fus_CDS = if (fuselage.enabled) fuselage.CDS else 0;
    for (ac.allBooms()) |boom| if (boom.enabled) {
        params.fus_CDS += 0.006 * std.math.pi * boom.diameter * boom.length; // atrito dos tubos
    };
    params.fus_Cma = if (fuselage.enabled) fuselage.Cma else 0;
    params.fus_Cnb = if (fuselage.enabled) fuselage.Cnb else 0;
    params.fus_CYb = if (fuselage.enabled) fuselage.CYb else 0;
    params.fus_r = fuselage.aero_point orelse .{ fuselage.x_nose - 0.4 * fuselage.length, 0, fuselage.z };

    const downwash = try wingDownwash(ac);
    const out: Panels = .{ .params = params, .diag = diag };
    for (ac.surfaces, 0..) |*s, owner| {
        if (!s.enabled or s.sections.len < 2) continue;
        surfacePanels(out, ac, s, owner, downwash) catch |err| {
            if (err == error.InvalidAirfoil or err == error.TooManyPoints) diag.set("{s}: perfil inválido", .{s.name});
            return err;
        };
        try devicePanels(out, ac, s);
    }

    var units: usize = 0;
    for (ac.propulsion) |unit| units += @intFromBool(unit.enabled);
    const unit_count: f64 = @floatFromInt(@max(units, 1));
    if (units > limits.max_props) {
        diag.set("motores demais (máximo {d})", .{limits.max_props});
        return error.TooManyProps;
    }
    for (ac.propulsion) |unit| {
        if (!unit.enabled) continue;
        const propeller = unit.propeller;
        const thrust_poly = unit.thrust_poly;
        var prop_unit: types.PropUnit = .{
            .model = if (std.mem.eql(u8, unit.thrust_model, "poly")) types.ThrustModel.polynomial else types.ThrustModel.motor,
            .poly_x = polyVar(thrust_poly.x_var),
            .poly_y = polyVar(thrust_poly.y_var),
            .poly_gain = thrust_poly.gain,
            .poly_rho_exp = thrust_poly.rho_exp,
            .poly_rho0 = thrust_poly.rho0,
            .poly_xmax = thrust_poly.xmax,
            .poly_ymax = thrust_poly.ymax,
            .poly_xc = thrust_poly.x_const,
            .poly_yc = thrust_poly.y_const,
            .r = .{ unit.x, unit.y, unit.z },
            .tilt = unit.tilt * D2R,
            .tilt_range = unit.tilt_range * D2R,
            .toe = unit.toe * D2R,
            .sense = unit.sense,
            .D = propeller.D,
            .Ip = propeller.Ip,
            .Jm = unit.motor.Jm,
            .Kv = unit.motor.Kv,
            .Rm = unit.motor.Rm,
            .B = unit.motor.B,
            .tauc = unit.motor.tauc,
            .Imax = unit.motor.Imax,
            .Voc = unit.battery.voc(),
            .Rint = unit.battery.Rint * (if (ac.shared_battery) unit_count else 1),
            .P_lim = if (ac.power_limit > 0) ac.power_limit / unit_count else 0,
            .yaw_mix = unit.yaw_mix,
        };
        for (thrust_poly.coefs[0..@min(thrust_poly.coefs.len, prop_unit.poly.len)], 0..) |coefficient, i| prop_unit.poly[i] = coefficient;
        const point_count = @min(propeller.J.len, propeller.CT.len, propeller.CP.len, limits.max_prop_pts);
        for (0..point_count) |i| {
            prop_unit.J[i] = propeller.J[i];
            prop_unit.CT[i] = propeller.CT[i];
            prop_unit.CP[i] = propeller.CP[i];
        }
        prop_unit.n_pts = @intCast(point_count);
        params.prop[@intCast(params.n_prop)] = prop_unit;
        params.n_prop += 1;
    }

    const gear = ac.gear;
    var legs: [model.limits.gear_legs]sk.Leg = undefined;
    const leg_count = sk.gearLegs(gear, &legs);
    if (leg_count > limits.max_gear) {
        diag.set("trem: {d} pernas (máximo {d})", .{ leg_count, limits.max_gear });
        return error.TooMany;
    }
    const custom = std.mem.eql(u8, gear.layout, "custom");
    for (legs[0..leg_count], 0..) |leg, i| {
        // pernas padrão: 0 bequilha, 1-2 principais, 3 patim (igual a LandingGear.legs)
        const kind: types.GearKind, const stiffness: f64, const damping: f64 = if (custom) .{
            if (std.mem.eql(u8, gear.custom[i].kind, "steer")) types.GearKind.steer else if (std.mem.eql(u8, gear.custom[i].kind, "skid")) types.GearKind.skid else types.GearKind.main,
            gear.custom[i].k,
            gear.custom[i].c,
        } else switch (i) {
            0 => .{ types.GearKind.steer, gear.steer_k, gear.steer_c },
            1, 2 => .{ types.GearKind.main, gear.main_k, gear.main_c },
            else => .{ types.GearKind.skid, gear.skid_k, gear.skid_c },
        };
        params.gear[i] = .{ .r = .{ leg.x, leg.y, leg.z }, .k = stiffness, .c = damping, .kind = kind };
    }
    params.n_gear = @intCast(leg_count);

    for (ac.tanks, 0..) |tank, i| {
        params.tank[i] = .{ .r = .{ tank.x, tank.y, tank.z }, .side = tank.side, .fill = tank.fill(), .rho = tank.rho, .zeta = tank.zeta, .shape = if (std.mem.eql(u8, tank.shape, "square")) types.TankShape.square else types.TankShape.cylinder };
    }
    params.n_tank = @intCast(ac.tanks.len);
    params.slosh_on = @intFromBool(ac.sim.slosh);
    params.mu_roll = gear.mu_roll;
    params.mu_lat = gear.mu_lat;
    params.mu_brake = gear.mu_brake;
    params.mu_skid = gear.mu_skid;
    params.mu_landing = gear.mu_landing;
    const payload = ac.payload;
    params.payload = .{ .enabled = @intFromBool(payload.enabled), .m = payload.mass, .r = .{ payload.x, payload.y, payload.z }, .bay = payload.bay, .Fext_g = payload.Fext_g, .mu_b = payload.mu_b, .CdS_chute = payload.CdS_chute };
    const environment = ac.environment;
    params.env = .{ .rho = environment.rho, .Vw10 = environment.wind_speed, .wind_from = environment.wind_from * D2R, .wind_elev = environment.wind_elev * D2R, .h_ref = environment.h_ref, .gust_T = environment.gust_T, .gust_on = @intFromBool(environment.gust) };
    for (environment.gust_U[0..@min(environment.gust_U.len, 3)], 0..) |x, i| params.env.gust_U[i] = x;
    const takeoff = ac.takeoff;
    params.takeoff = .{ .VR = takeoff.VR, .sR = takeoff.sR, .de0 = takeoff.de0 * D2R, .de1 = takeoff.de1 * D2R, .rate_de = takeoff.rate_de * D2R, .ht = takeoff.ht, .rate_thr = takeoff.rate_thr, .h_end = takeoff.h_end, .alpha_guard = 1 }; // proteção de α sempre ligada
    inline for (@typeInfo(types.Autopilot).@"struct".fields) |field| {
        const value = @field(ac.autopilot, field.name);
        const angle = comptime for ([_][]const u8{ "alpha_max", "chi_inf", "phimax", "pmax_cmd", "de_max", "da_max", "dr_max" }) |stiffness| {
            if (std.mem.eql(u8, stiffness, field.name)) break true;
        } else false;
        @field(params.ap, field.name) = if (angle) value * D2R else value;
    }
    params.dt = ac.sim.dt;
    params.tmax = ac.sim.tmax;
    params.dtlog = ac.sim.dtlog;
    const segment_count = try mission.segments(&ac.mission, &params.seg, diag);
    params.n_seg = @intCast(segment_count);
    params.n_event = @intCast(try mission.events(&ac.mission, &params.event, diag));
    params.n_pad = @intCast(mission.pads(&ac.airfield, params.seg[0..segment_count], &params.pads));
    methods.fixed.apply(params); // o modelo do voo e o refino: fixos no AeroDrive (methods.zig)
    modifiers.fill(ac, params); // efeito solo e efeitos a mais: do arquivo, como na GUI
}

/// parâmetros + configuração do núcleo + calibração do piloto (como `prepare` da GUI), com os métodos fixos do
/// AeroDrive (`methods.zig`)
pub fn setup(ac: *const Aircraft, inst: *core.runner.Instance, diag: *model.Diag) Error!Info {
    return setupWith(ac, inst, diag, methods.fixed);
}

/// como `setup`, com os métodos de cálculo escolhidos (`core.methods`; as análises da interface deixam o usuário
/// escolher)
pub fn setupWith(ac: *const Aircraft, inst: *core.runner.Instance, diag: *model.Diag, chosen: core.methods.Methods) Error!Info {
    try fill(ac, &inst.p, diag);
    chosen.apply(&inst.p);
    core.runner.configure(inst) catch |e| {
        diag.set("o núcleo recusou a configuração ({s})", .{@errorName(e)});
        return error.CoreConfig;
    };
    return calibrate(ac, inst, diag);
}

/// as características estáticas e a calibração do piloto (C_L0, C_Lα, o acelerador de equilíbrio e os ganhos) de um
/// avião já configurado em `inst`; quem muda os parâmetros antes (uma massa a mais, o CG) chama `fill`, muda,
/// configura e chama esta
pub fn calibrate(ac: *const Aircraft, inst: *core.runner.Instance, diag: *model.Diag) Error!Info {
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
        const tp = core.trim.solve(core.trim.Ctx.init(&inst.p, &inst.r.f), types.TrimKind.level, Vc, 1.0, null);
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
    var cm_sum: f64 = 0; // o ajuste de C_m contra C_L (margem estática)
    var cm_cl_sum: f64 = 0;
    var cl_squares: f64 = 0;
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
            cm_sum += co.Cm;
            cm_cl_sum += co.CL * co.Cm;
            cl_squares += co.CL * co.CL;
            n += 1;
        }
        if (co.CL > best) {
            best = co.CL;
            a_best = a;
        }
    }
    const CLa = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    const CL0 = (sy - CLa * sx) / n;
    const dCm_dCL = (n * cm_cl_sum - sy * cm_sum) / (n * cl_squares - sy * sy);
    const S = references(ac)[0];
    return .{
        .mass = tc.m,
        .CL0 = CL0,
        .CLa = CLa,
        .CLmax = best,
        .alpha_stall_deg = a_best / D2R,
        .static_margin = -dCm_dCL,
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

test "perfil por seção: faixas iguais às do tradutor da GUI" {
    var d: model.Diag = .{};
    var l = try model.parse(testing.allocator,
        \\{"aeronave": {"name": "perfis", "surfaces": [{"name": "asa", "airfoil": {"name": "NACA 4412", "cl_alpha": 6.0, "cl_max": 1.6, "cd0": 0.012},
        \\ "sections": [{"y": 0, "chord": 0.3}, {"y": 0.5, "chord": 0.25}, {"y": 1.0, "chord": 0.2, "airfoil": {"name": "NACA 0012", "cl_alpha": 5.7, "cl_max": 1.2, "cd0": 0.009}}],
        \\ "controls": [{"kind": "aileron", "span_start": 0.6, "span_end": 1.0}]}]}}
    , &d);
    defer l.deinit();
    const p = try testing.allocator.create(types.Params);
    defer testing.allocator.destroy(p);
    p.* = .{};
    try surfacePanels(.{ .params = p, .diag = &d }, &l.ac, &l.ac.surfaces[0], 0, .{ 0, 0 });
    // números do aerosim (universal + translator.surface_panels), um por faixa (direita e esquerda iguais)
    const ref = [_][5]f64{
        .{ 4.736215888000, 0.349680860090, 1.440, 0.0120, -0.105505584582 },
        .{ 4.718010141184, 0.313503035923, 1.404, 0.0117, -0.094955026124 },
        .{ 4.626270658837, 0.136625385434, 1.224, 0.0102, -0.042202233833 },
    };
    try testing.expectEqual(@as(i32, 6), p.n_surf);
    for (ref, 0..) |r, k| for (0..2) |side| {
        const q = p.surf[2 * k + side];
        const got = [5]f64{ q.CLa, q.CL0, q.CLmax, q.CD0, q.Cmac };
        for (0..5) |i| try testing.expectApproxEqAbs(r[i], got[i], 1e-9);
    };
    const co = try coeffs(&l.ac.surfaces[0]);
    try testing.expectApproxEqAbs(@as(f64, 4.695039901319566), co.CLa, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.08176682805099032), co.Cmac, 1e-9);
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
    var p: types.Params = undefined;
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
    var p: types.Params = undefined;
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
