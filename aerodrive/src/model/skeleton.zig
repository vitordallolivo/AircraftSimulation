//! Esqueleto da aeronave: as peças que se desenham, cada uma com o seu *driver* (como se move).
//!
//! Mesmas formas e cores da GUI (`aerosim/model/geometry.py` + `universal.py`): superfícies pelo
//! perfil, comandos, dispositivos de ponta, fuselagem, tubo, motores e hélices, tanques e líquido,
//! LAPES, lastro e trem. A diferença: aqui cada comando é uma peça separada com dobradiça, para
//! defletir. A física não lê nada daqui.
//!
//! Corpo: x para a frente, y para a direita, z para baixo (metros).
//!
//! Drivers:
//!   fixed     preso ao corpo
//!   hinge     δ = mix · (δe, δa, δr) [+ ângulo fixo do flape] em torno da articulação;
//!             δ > 0 leva o bordo de fuga para o lado oposto à normal (convenção do núcleo)
//!   spin      hélice: gira com rpm[unit] em torno do eixo de tração
//!   liquid    superfície do líquido do tanque `tank` (inclina com o sloshing)
//!   payload   carga LAPES (sai da aeronave na soltura)
const std = @import("std");
const fz = @import("../util/fuzz.zig");
const v3 = @import("../math/vec3.zig");
const model = @import("aircraft.zig");
const airfoil = @import("airfoil.zig");

const V3 = v3.V3;
const Aircraft = model.Aircraft;
const Surface = model.Surface;

pub const Color = enum { wing, htail, vtail, control, device, fuselage, boom, motor, propdisk, blade, tank, liquid, payload, ballast, wheel, strut };

/// as cores da GUI (r, g, b, a)
pub fn rgba(c: Color) [4]f32 {
    return switch (c) {
        .wing => .{ 0.30, 0.55, 0.85, 1.0 },
        .htail => .{ 0.35, 0.70, 0.45, 1.0 },
        .vtail => .{ 0.55, 0.45, 0.80, 1.0 },
        .control => .{ 0.95, 0.65, 0.15, 1.0 },
        .device => .{ 0.20, 0.62, 0.62, 1.0 },
        .fuselage => .{ 0.75, 0.75, 0.78, 1.0 },
        .boom => .{ 0.4, 0.4, 0.42, 1.0 },
        .motor => .{ 0.85, 0.25, 0.25, 1.0 },
        .propdisk => .{ 0.9, 0.3, 0.3, 0.25 },
        .blade => .{ 0.15, 0.15, 0.15, 1.0 },
        .tank => .{ 0.6, 0.85, 0.95, 0.25 },
        .liquid => .{ 0.15, 0.45, 0.95, 0.75 },
        .payload => .{ 0.55, 0.35, 0.15, 1.0 },
        .ballast => .{ 0.25, 0.25, 0.28, 1.0 },
        .wheel => .{ 0.1, 0.1, 0.1, 1.0 },
        .strut => .{ 0.3, 0.3, 0.3, 1.0 },
    };
}

pub const Mesh = struct {
    v: []V3, // vértices no corpo
    f: [][3]u32, // triângulos
};

pub const Driver = union(enum) {
    fixed,
    hinge: struct { p: V3, d: V3, mix: [3]f64, angle_deg: f64 },
    spin: struct { p: V3, d: V3, unit: u8, sense: f64 },
    liquid: struct { tank: u8, p: V3 },
    payload: struct { r: V3 },
};

pub const Piece = struct {
    id: []const u8,
    component: []const u8, // a chave da GUI: "surface:0", "prop:1", "gear", ...
    color: Color,
    mesh: Mesh,
    driver: Driver = .fixed,
};

pub const Skeleton = struct {
    arena: std.heap.ArenaAllocator,
    pieces: []Piece,

    pub fn deinit(s: *Skeleton) void {
        s.arena.deinit();
    }

    /// raio da esfera que envolve tudo (para a câmera enquadrar)
    pub fn radius(s: *const Skeleton) f64 {
        var r: f64 = 0.1;
        for (s.pieces) |p| for (p.mesh.v) |q| {
            r = @max(r, v3.norm(q));
        };
        return r;
    }
};

pub const Error = model.Error || airfoil.Error || std.mem.Allocator.Error;

/// deflexão por comando: (δe, δa, δr) -> δ da faixa; side = +1 direita, −1 esquerda, 0 no plano de
/// simetria (igual a `panel_mix` do tradutor): rolagem antissimétrica, guinada também quando espelhada
pub fn controlMix(c: model.Control, side: f64) [3]f64 {
    const g = c.gains();
    return .{ g[0], -side * g[1], -(if (side != 0) side else 1) * g[2] };
}

test "mistura de comandos: o tipo é nome; a mistura manda (igual a panel_mix)" {
    const elevon: model.Control = .{ .kind = "elevon" };
    const livre: model.Control = .{ .kind = "meu comando", .mix = .{ 0.5, 1, 0 } };
    const leme: model.Control = .{ .kind = "rudder" };
    try std.testing.expectEqual([3]f64{ 1, -1, 0 }, controlMix(elevon, 1));
    try std.testing.expectEqual([3]f64{ 0.5, 1, 0 }, controlMix(livre, -1));
    try std.testing.expectEqual([3]f64{ 0, 0, -1 }, controlMix(leme, 0));
    try std.testing.expectEqualStrings("elevon", livre.role());
    try std.testing.expectEqualStrings("aileron", (model.Control{ .kind = "flaperon" }).role());
}

// ------------------------------------------------------------------ construção
const Builder = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(Piece) = .empty,

    fn add(b: *Builder, id: []const u8, comp: []const u8, color: Color, m: Mesh, drv: Driver) !void {
        try b.list.append(b.a, .{ .id = id, .component = comp, .color = color, .mesh = m, .driver = drv });
    }
    fn fmt(b: *Builder, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(b.a, f, args);
    }
};

/// monta o esqueleto (valide a aeronave antes: `model.validate`)
pub fn build(gpa: std.mem.Allocator, ac: *const Aircraft, diag: *model.Diag) Error!Skeleton {
    try model.validate(ac, diag);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var b: Builder = .{ .a = arena.allocator() };
    for (ac.surfaces, 0..) |*s, i| {
        if (!s.enabled) continue;
        try surfacePieces(&b, ac, s, i, diag);
        try devicePieces(&b, ac, s, i);
    }
    try bodyPieces(&b, ac);
    return .{ .arena = arena, .pieces = try b.list.toOwnedSlice(b.a) };
}

pub const Station = struct { s: f64, le: V3, chord: f64, twist: f64 };

/// estações nas quebras (seções + início/fim dos comandos), como `universal._surface`
pub fn stations(ac: *const Aircraft, s: *const Surface, out: *[model.limits.sections * 3]Station) []Station {
    var sbuf: [model.limits.sections]model.Section = undefined;
    const ss = model.sortedSections(s, &sbuf);
    const bspan = model.semispan(s);
    var ys: [model.limits.sections + 2 * model.limits.controls]f64 = undefined;
    var n: usize = 0;
    for (ss) |q| {
        ys[n] = q.y;
        n += 1;
    }
    for (s.controls) |c| {
        ys[n] = std.math.clamp(c.span_start, 0, 1) * bspan;
        ys[n + 1] = std.math.clamp(c.span_end, 0, 1) * bspan;
        n += 2;
    }
    for (ys[0..n]) |*y| y.* = std.math.clamp(y.*, 0, bspan);
    std.mem.sort(f64, ys[0..n], {}, std.sort.asc(f64));
    const pos = model.tailOnBoom(ac, s);
    const dih = std.math.degreesToRadians(s.dihedral);
    var k: usize = 0;
    for (ys[0..n]) |y| {
        if (k > 0 and y - out[k - 1].s <= 1e-9) continue;
        const xo = model.sectionAt(ss, y, "x_offset");
        const le: V3 = if (s.vertical) .{ pos.x - xo, s.y, pos.z - y } else .{ pos.x - xo, s.y + y * @cos(dih), pos.z - y * @sin(dih) };
        out[k] = .{ .s = y, .le = le, .chord = model.sectionAt(ss, y, "chord"), .twist = s.incidence + model.sectionAt(ss, y, "twist") };
        k += 1;
    }
    return out[0..k];
}

pub fn controlAt(s: *const Surface, y: f64) ?model.Control {
    const bspan = model.semispan(s);
    for (s.controls) |c| {
        if (c.span_start * bspan - 1e-9 <= y and y <= c.span_end * bspan + 1e-9) return c;
    }
    return null;
}

/// normal do lado direito (direção da espessura; para cima, ou +y na vertical)
pub fn frame(vertical: bool, root: V3, tip: V3) V3 {
    if (vertical) return .{ 0, 1, 0 };
    const d = v3.sub(tip, root);
    const u = v3.unit(.{ 0, d[1], d[2] }, .{ 0, 1, 0 });
    return .{ 0, u[2], -u[1] };
}

fn ring(a: std.mem.Allocator, q: Station, prof: []const [2]f64, n: V3, vertical: bool, mir: V3) ![]V3 {
    const r = try a.alloc(V3, prof.len);
    const tw = if (vertical) 0.0 else std.math.degreesToRadians(q.twist);
    for (prof, r) |p, *o| {
        const xs = -p[0] * q.chord;
        const th = p[1] * q.chord;
        const xr = xs * @cos(tw) - th * @sin(tw);
        const tr = xs * @sin(tw) + th * @cos(tw);
        o.* = v3.mul(v3.add(q.le, v3.add(.{ xr, 0, 0 }, v3.scale(n, tr))), mir);
    }
    return r;
}

/// liga anéis consecutivos (e tampa as pontas) — `_loft` da GUI
fn loft(a: std.mem.Allocator, rings: []const []const V3, cap: bool) !Mesh {
    const n = rings[0].len;
    var v: std.ArrayList(V3) = .empty;
    var f: std.ArrayList([3]u32) = .empty;
    for (rings) |r| try v.appendSlice(a, r);
    for (0..rings.len - 1) |k| {
        const p: u32 = @intCast(k * n);
        const q: u32 = @intCast((k + 1) * n);
        for (0..n) |ii| {
            const i: u32 = @intCast(ii);
            const j: u32 = @intCast((ii + 1) % n);
            try f.append(a, .{ p + i, q + i, q + j });
            try f.append(a, .{ p + i, q + j, p + j });
        }
    }
    if (cap) {
        for ([_]usize{ 0, (rings.len - 1) * n }) |base_| {
            const base: u32 = @intCast(base_);
            for (1..n - 1) |ii| {
                const i: u32 = @intCast(ii);
                try f.append(a, .{ base, base + i, base + i + 1 });
            }
        }
    }
    return .{ .v = try v.toOwnedSlice(a), .f = try f.toOwnedSlice(a) };
}

fn roleColor(role: []const u8) Color {
    if (std.mem.eql(u8, role, "htail")) return .htail;
    if (std.mem.eql(u8, role, "vtail")) return .vtail;
    return .wing;
}

fn drawingProfile(s: *const Surface, af: model.Airfoil, out: *airfoil.Profile, diag: *model.Diag) Error!void {
    airfoil.forDrawing(af.name, af.coords, out) catch |e| {
        diag.set("{s}: perfil inválido", .{s.name});
        return e;
    };
    if (af.inverted) airfoil.invert(out);
}

fn surfacePieces(b: *Builder, ac: *const Aircraft, s: *const Surface, index: usize, diag: *model.Diag) Error!void {
    var prof0: airfoil.Profile = .{};
    try drawingProfile(s, s.airfoil, &prof0, diag);
    const mixed = model.mixedAirfoils(s) and s.sections.len > 1;
    var secbuf: [model.limits.sections]model.Section = undefined;
    const ss = model.sortedSections(s, &secbuf);
    var strip_prof: airfoil.Profile = .{};
    var sbuf: [model.limits.sections * 3]Station = undefined;
    const st = stations(ac, s, &sbuf);
    if (st.len < 2) return;
    const n0 = frame(s.vertical, st[0].le, st[st.len - 1].le);
    const comp = try b.fmt("surface:{d}", .{index});
    const mirror = s.symmetric and !s.vertical;
    const sides: []const f64 = if (mirror) &.{ 1, -1 } else &.{1};
    for (sides) |sy| {
        const mir: V3 = .{ 1, sy, 1 };
        const tag = if (sy > 0) "D" else "E";
        for (st[0 .. st.len - 1], st[1..], 0..) |qa, qb, k| {
            const ctl = controlAt(s, 0.5 * (qa.s + qb.s));
            var prof = &prof0;
            if (mixed) { // perfil por seção: a faixa com o perfil da seção mais perto do meio dela
                const ym = 0.5 * (qa.s + qb.s);
                var near = ss[0];
                for (ss) |q| if (@abs(q.y - ym) < @abs(near.y - ym)) {
                    near = q;
                };
                try drawingProfile(s, near.airfoil orelse s.airfoil, &strip_prof, diag);
                prof = &strip_prof;
            }
            if (ctl == null) {
                const m = try loft(b.a, &.{ try ring(b.a, qa, prof.slice(), n0, s.vertical, mir), try ring(b.a, qb, prof.slice(), n0, s.vertical, mir) }, true);
                try b.add(try b.fmt("{s}/{d}/{s}", .{ s.name, k, tag }), comp, roleColor(s.role), m, .fixed);
                continue;
            }
            const c = ctl.?;
            const xh = 1.0 - std.math.clamp(c.chord_frac, 0.05, 0.9);
            var main: airfoil.Profile = .{};
            var flap: airfoil.Profile = .{};
            const h = airfoil.split(prof.slice(), xh, &main, &flap);
            const mm = try loft(b.a, &.{ try ring(b.a, qa, main.slice(), n0, s.vertical, mir), try ring(b.a, qb, main.slice(), n0, s.vertical, mir) }, true);
            try b.add(try b.fmt("{s}/{d}/{s}", .{ s.name, k, tag }), comp, roleColor(s.role), mm, .fixed);
            const fm = try loft(b.a, &.{ try ring(b.a, qa, flap.slice(), n0, s.vertical, mir), try ring(b.a, qb, flap.slice(), n0, s.vertical, mir) }, true);
            const pa = (try ring(b.a, qa, &.{h}, n0, s.vertical, mir))[0];
            const pb = (try ring(b.a, qb, &.{h}, n0, s.vertical, mir))[0];
            var d = v3.unit(v3.sub(pb, pa), .{ 0, 1, 0 });
            // δ > 0: bordo de fuga para −normal -> eixo no sentido de normal × (−x)
            if (v3.dot(d, v3.cross(v3.mul(n0, mir), .{ -1, 0, 0 })) < 0) d = v3.scale(d, -1);
            try b.add(try b.fmt("{s}/{s}/{d}/{s}", .{ s.name, c.kind, k, tag }), comp, .control, fm, .{ .hinge = .{ .p = pa, .d = d, .mix = controlMix(c, sy), .angle_deg = c.deflection } });
        }
    }
}

/// winglet, winglet para baixo, placa e cerca (`devices.legs` + `universal._devices`)
fn devicePieces(b: *Builder, ac: *const Aircraft, s: *const Surface, index: usize) Error!void {
    if (s.vertical) return;
    var sbuf: [model.limits.sections]model.Section = undefined;
    const ss = model.sortedSections(s, &sbuf);
    const pos = model.tailOnBoom(ac, s);
    const comp = try b.fmt("surface:{d}", .{index});
    for (s.devices, 0..) |d, k| {
        if (!d.enabled or d.height <= 0) continue;
        const y = std.math.clamp(d.eta, 0, 1) * model.semispan(s);
        const dih = std.math.degreesToRadians(s.dihedral);
        const le0: V3 = .{ pos.x - model.sectionAt(ss, y, "x_offset") - d.dx, s.y + y * @cos(dih), pos.z - y * @sin(dih) };
        const c0 = if (d.root_chord > 0) d.root_chord else model.sectionAt(ss, y, "chord");
        const cerca = std.mem.eql(u8, d.kind, "cerca");
        const ct = if (cerca) c0 else c0 * d.taper;
        const cant = std.math.degreesToRadians(d.cant);
        const sweep = if (cerca) 0.0 else std.math.degreesToRadians(d.sweep);
        const Part = struct { up: bool, h: f64 };
        const parts: []const Part = if (std.mem.eql(u8, d.kind, "winglet_baixo")) &.{.{ .up = false, .h = d.height }} else if (std.mem.eql(u8, d.kind, "placa")) &.{ .{ .up = true, .h = d.height / 2 }, .{ .up = false, .h = d.height / 2 } } else &.{.{ .up = true, .h = d.height }};
        var prof: airfoil.Profile = .{};
        try airfoil.forDrawing(d.profile, &.{}, &prof);
        for (parts, 0..) |part, j| {
            const u: V3 = if (cerca) .{ 0, 0, -1 } else .{ 0, @sin(cant), if (part.up) -@cos(cant) else @cos(cant) };
            var st: [4]Station = undefined;
            for (&st, 0..) |*q, i| {
                const hh = part.h * @as(f64, @floatFromInt(i)) / 3.0;
                const f = if (part.h > 0) hh / part.h else 0.0;
                q.* = .{ .s = hh, .le = v3.sub(v3.add(le0, v3.scale(u, hh)), .{ hh * @tan(sweep), 0, 0 }), .chord = c0 + f * (ct - c0), .twist = d.toe * @as(f64, if (part.up) 1 else -1) };
            }
            const n = frame(false, st[0].le, st[3].le);
            const sides: []const f64 = if (s.symmetric) &.{ 1, -1 } else &.{1};
            for (sides) |sy| {
                const mir: V3 = .{ 1, sy, 1 };
                var rings: [4][]const V3 = undefined;
                for (&rings, st) |*r, q| r.* = try ring(b.a, q, prof.slice(), n, false, mir);
                try b.add(try b.fmt("{s}/{s} {d}.{d}/{s}", .{ s.name, d.kind, k + 1, j + 1, if (sy > 0) "D" else "E" }), comp, .device, try loft(b.a, &rings, true), .fixed);
            }
        }
    }
}

fn ellipsoid(a: std.mem.Allocator, x_nose: f64, length: f64, width: f64, height: f64, z: f64) !Mesh {
    const n_len = 24;
    const n_ring = 20;
    var rings: [n_len + 1][]const V3 = undefined;
    for (&rings, 0..) |*r, i| {
        const f = @as(f64, @floatFromInt(i)) / n_len;
        var prof = if (f < 0.3) @sin(std.math.pi * @min(f / 0.3, 1.0) / 2) else 1.0 - 0.75 * std.math.pow(f64, (f - 0.3) / 0.7, 1.5);
        prof = @max(prof, 0.02);
        const x = x_nose - f * length;
        const rr = try a.alloc(V3, n_ring);
        for (rr, 0..) |*q, k| {
            const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / n_ring;
            q.* = .{ x, 0.5 * width * prof * @cos(t), z + 0.5 * height * prof * @sin(t) };
        }
        r.* = rr;
    }
    return loft(a, &rings, true);
}

fn cylinder(a: std.mem.Allocator, p0: V3, p1: V3, radius: f64, n: usize) !Mesh {
    const ax = v3.unit(v3.sub(p1, p0), .{ 0, 0, 1 });
    const t = v3.unit(if (@abs(ax[2]) < 0.9) v3.cross(ax, .{ 0, 0, 1 }) else v3.cross(ax, .{ 0, 1, 0 }), .{ 1, 0, 0 });
    const u = v3.cross(ax, t);
    const r0 = try a.alloc(V3, n);
    const r1 = try a.alloc(V3, n);
    for (r0, r1, 0..) |*q0, *q1, k| {
        const ang = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        const o = v3.add(v3.scale(t, radius * @cos(ang)), v3.scale(u, radius * @sin(ang)));
        q0.* = v3.add(p0, o);
        q1.* = v3.add(p1, o);
    }
    return loft(a, &.{ r0, r1 }, true);
}

fn box(a: std.mem.Allocator, c: V3, size: V3) !Mesh {
    const v = try a.alloc(V3, 8);
    var k: usize = 0;
    for ([_]f64{ -1, 1 }) |x| for ([_]f64{ -1, 1 }) |y| for ([_]f64{ -1, 1 }) |z| {
        v[k] = v3.add(c, v3.mul(.{ x, y, z }, v3.scale(size, 0.5)));
        k += 1;
    };
    const f = try a.dupe([3]u32, &.{ .{ 0, 1, 3 }, .{ 0, 3, 2 }, .{ 4, 6, 7 }, .{ 4, 7, 5 }, .{ 0, 4, 5 }, .{ 0, 5, 1 }, .{ 2, 3, 7 }, .{ 2, 7, 6 }, .{ 0, 2, 6 }, .{ 0, 6, 4 }, .{ 1, 5, 7 }, .{ 1, 7, 3 } });
    return .{ .v = v, .f = f };
}

pub fn thrustAxis(tilt_deg: f64, toe_deg: f64) V3 {
    const t = std.math.degreesToRadians(tilt_deg);
    const p = std.math.degreesToRadians(toe_deg);
    return .{ @cos(t) * @cos(p), @cos(t) * @sin(p), -@sin(t) };
}

pub const Leg = struct { x: f64, y: f64, z: f64 };

/// pernas do trem pelo tipo (igual a `LandingGear.legs`); devolve quantas
pub fn gearLegs(g: model.Gear, out: *[model.limits.gear_legs]Leg) usize {
    if (std.mem.eql(u8, g.layout, "custom")) {
        const n = @min(g.custom.len, out.len);
        for (g.custom[0..n], out[0..n]) |q, *o| o.* = .{ .x = q.x, .y = q.y, .z = q.z };
        return n;
    }
    out[0] = .{ .x = g.steer_x, .y = 0, .z = g.steer_z };
    out[1] = .{ .x = g.main_x, .y = -g.main_track / 2, .z = g.main_z };
    out[2] = .{ .x = g.main_x, .y = g.main_track / 2, .z = g.main_z };
    if (std.mem.eql(u8, g.layout, "tricycle") and g.tail_skid) {
        out[3] = .{ .x = g.skid_x, .y = 0, .z = g.skid_z };
        return 4;
    }
    return 3;
}

fn bodyPieces(b: *Builder, ac: *const Aircraft) Error!void {
    const a = b.a;
    const f = ac.fuselage;
    if (f.enabled) try b.add("fuselagem", "fuselage", .fuselage, try ellipsoid(a, f.x_nose, f.length, f.width, f.height, f.z), .fixed);
    for (ac.allBooms()) |bm| if (bm.enabled) {
        try b.add(bm.name, "boom", .boom, try cylinder(a, bm.start(), bm.end(), bm.diameter / 2, 16), .fixed);
    };
    var unit: u8 = 0;
    for (ac.propulsion, 0..) |u, i| {
        if (!u.enabled) continue;
        const e = thrustAxis(u.tilt, u.toe);
        const p: V3 = .{ u.x, u.y, u.z };
        const D = u.propeller.D;
        const k: f64 = if (u.x < 0) 1.0 else -1.0; // propulsora: motor à frente da hélice; tratora: atrás
        const comp = try b.fmt("prop:{d}", .{i});
        try b.add(try b.fmt("{s}/motor", .{u.name}), comp, .motor, try cylinder(a, v3.add(p, v3.scale(e, k * 0.12)), v3.add(p, v3.scale(e, k * 0.01)), 0.035, 16), .fixed);
        try b.add(try b.fmt("{s}/disco", .{u.name}), comp, .propdisk, try cylinder(a, p, v3.add(p, v3.scale(e, 0.004)), D / 2, 32), .fixed);
        const t = v3.unit(v3.cross(e, .{ 0, 0, 1 }), .{ 0, 1, 0 });
        const w = v3.cross(e, t);
        const blade = try box(a, .{ 0, 0, 0 }, .{ 0.006, D, 0.025 });
        for (blade.v) |*q| q.* = v3.add(v3.add(v3.add(v3.scale(e, q[0]), v3.scale(t, q[1])), v3.scale(w, q[2])), v3.add(p, v3.scale(e, 0.006)));
        try b.add(try b.fmt("{s}/pá", .{u.name}), comp, .blade, blade, .{ .spin = .{ .p = p, .d = e, .unit = unit, .sense = if (u.sense < 0) -1 else 1 } });
        unit += 1;
    }
    for (ac.tanks, 0..) |t, i| {
        const comp = try b.fmt("tank:{d}", .{i});
        const fill = t.fill();
        try b.add(try b.fmt("{s}/tanque", .{t.name}), comp, .tank, try box(a, .{ t.x, t.y, t.z }, .{ t.side, t.side, @max(t.height, fill) }), .fixed);
        if (fill > 0) try b.add(try b.fmt("{s}/líquido", .{t.name}), comp, .liquid, try box(a, .{ t.x, t.y, t.z + t.height / 2 - fill / 2 }, .{ t.side * 0.96, t.side * 0.96, fill }), .{ .liquid = .{ .tank = @intCast(i), .p = .{ t.x, t.y, t.z + t.height / 2 - fill } } });
    }
    if (ac.payload.enabled) {
        const P = ac.payload;
        try b.add("LAPES", "payload", .payload, try box(a, .{ P.x, P.y, P.z }, .{ 0.18, 0.12, 0.08 }), .{ .payload = .{ .r = .{ P.x, P.y, P.z } } });
    }
    if (ac.ballast.enabled) {
        const B = ac.ballast;
        const sz = std.math.clamp(std.math.cbrt(B.mass / 7800.0) * 1.6, 0.03, 0.12); // cubo de aço com a massa
        try b.add("lastro", "ballast", .ballast, try box(a, .{ B.x, B.y, B.z }, .{ sz, sz, sz }), .fixed);
    }
    var legs: [model.limits.gear_legs]Leg = undefined;
    for (legs[0..gearLegs(ac.gear, &legs)], 0..) |g, j| {
        try b.add(try b.fmt("trem/{d}/roda", .{j}), "gear", .wheel, try box(a, .{ g.x, g.y, g.z }, .{ 0.06, 0.025, 0.06 }), .fixed);
        try b.add(try b.fmt("trem/{d}/perna", .{j}), "gear", .strut, try cylinder(a, .{ g.x, g.y, 0 }, .{ g.x, g.y, g.z }, 0.006, 8), .fixed);
    }
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

fn checkSkeleton(sk: *const Skeleton) !void {
    try testing.expect(sk.pieces.len > 0);
    for (sk.pieces) |p| {
        for (p.mesh.v) |q| try testing.expect(v3.finite(q));
        for (p.mesh.f) |t| for (t) |i| try testing.expect(i < p.mesh.v.len);
        switch (p.driver) {
            .hinge => |h| try testing.expectApproxEqAbs(@as(f64, 1), v3.norm(h.d), 1e-9),
            .spin => |s| try testing.expectApproxEqAbs(@as(f64, 1), v3.norm(s.d), 1e-9),
            else => {},
        }
    }
}

test "asa com aileron: duas peças por faixa com comando, dobradiça na linha de 75 % da corda" {
    const secs = [_]model.Section{ .{ .y = 0, .chord = 0.4 }, .{ .y = 1.25, .chord = 0.4 } };
    const ctl = [_]model.Control{.{ .kind = "aileron", .span_start = 0.6, .span_end = 1, .chord_frac = 0.25 }};
    const surf = [_]Surface{.{ .name = "asa", .x = 0.1, .sections = &secs, .controls = &ctl }};
    var d: model.Diag = .{};
    var sk = try build(testing.allocator, &.{ .surfaces = &surf }, &d);
    defer sk.deinit();
    try checkSkeleton(&sk);
    var hinges: usize = 0;
    for (sk.pieces) |p| switch (p.driver) {
        .hinge => |h| {
            hinges += 1;
            try testing.expectApproxEqAbs(@as(f64, 0.1 - 0.75 * 0.4), h.p[0], 1e-9);
            // aileron: lados com sinais opostos; eixo ao longo da envergadura (+y à direita)
            try testing.expectApproxEqAbs(@as(f64, 1), @abs(h.d[1]), 1e-9);
            try testing.expectEqual(-std.math.sign(h.p[1]), h.mix[1]);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), hinges);
}

test "δ > 0 leva o bordo de fuga para baixo no profundor e para −y no leme" {
    const secs = [_]model.Section{ .{ .y = 0, .chord = 0.2 }, .{ .y = 0.4, .chord = 0.2 } };
    const el = [_]model.Control{.{ .kind = "elevator", .span_start = 0, .span_end = 1, .chord_frac = 0.3 }};
    const ru = [_]model.Control{.{ .kind = "rudder", .span_start = 0, .span_end = 1, .chord_frac = 0.3 }};
    const surf = [_]Surface{
        .{ .name = "EH", .role = "htail", .sections = &secs, .controls = &el },
        .{ .name = "EV", .role = "vtail", .symmetric = false, .vertical = true, .sections = &secs, .controls = &ru },
    };
    var d: model.Diag = .{};
    var sk = try build(testing.allocator, &.{ .surfaces = &surf }, &d);
    defer sk.deinit();
    for (sk.pieces) |p| switch (p.driver) {
        .hinge => |h| {
            const te = v3.apply(v3.axisAngle(h.d, 0.3), .{ -1, 0, 0 });
            if (p.id[1] == 'H') try testing.expect(te[2] > 0.2) else try testing.expect(te[1] < -0.2);
        },
        else => {},
    };
}

test "os aviões de exemplo da pasta data/aircraft montam" {
    const files = [_][]const u8{ "Convencional_original.json", "Asa_voadora.json", "Bimotor_convencional_tubo_cauda_em_V.json", "Convencional_decola_da_mesa_pousa_na_plataforma.json" };
    for (files) |name| {
        const path = try std.fmt.allocPrint(testing.allocator, "../data/aircraft/{s}", .{name});
        defer testing.allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 24));
        defer testing.allocator.free(bytes);
        var d: model.Diag = .{};
        var l = try model.parse(testing.allocator, bytes, &d);
        defer l.deinit();
        var sk = try build(testing.allocator, &l.ac, &d);
        defer sk.deinit();
        try checkSkeleton(&sk);
        try testing.expect(sk.radius() > 0.3 and sk.radius() < 10);
    }
}

fn fuzzBuild(_: void, src: *fz.Src) anyerror!void {
    // geometria qualquer: build devolve erro previsto ou um esqueleto finito e consistente
    const F = fz.Src.mostly;
    var secs: [4]model.Section = undefined;
    var y: f64 = 0;
    for (&secs) |*q| {
        q.* = .{ .y = y, .chord = F(src, 0.02, 1), .x_offset = F(src, -0.3, 0.5), .twist = F(src, -10, 10) };
        y += F(src, 0, 1);
    }
    const kinds = [_][]const u8{ "aileron", "elevator", "rudder", "elevon", "ruddervator", "flap", "??" };
    const s0 = F(src, 0, 1);
    const ctl = [_]model.Control{.{ .kind = kinds[src.index(kinds.len)], .span_start = s0, .span_end = s0 + F(src, 0, 1), .chord_frac = F(src, 0.05, 0.6), .deflection = F(src, -30, 30) }};
    const dkinds = [_][]const u8{ "winglet", "winglet_baixo", "placa", "cerca" };
    const dev = [_]model.Device{.{ .kind = dkinds[src.index(dkinds.len)], .eta = F(src, 0, 1), .height = F(src, 0, 0.4), .taper = F(src, 0, 1.5), .sweep = F(src, -60, 60), .cant = F(src, -90, 90), .toe = F(src, -10, 10) }};
    const surf = [_]Surface{.{
        .sections = secs[0..src.int(u8, 1, 4)],
        .controls = ctl[0..src.int(u8, 0, 1)],
        .devices = dev[0..src.int(u8, 0, 1)],
        .dihedral = F(src, -20, 20),
        .incidence = F(src, -5, 5),
        .vertical = src.boolean(),
        .symmetric = src.boolean(),
    }};
    const props = [_]model.Propulsion{.{ .x = F(src, -1, 1), .tilt = F(src, -20, 20), .toe = F(src, -20, 20), .propeller = .{ .D = F(src, 0.05, 0.6) } }};
    const tanks = [_]model.Tank{.{ .side = F(src, 0.02, 0.4), .height = F(src, 0.02, 0.4), .volume = F(src, 0, 5) }};
    const layouts = [_][]const u8{ "tricycle", "conventional", "custom", "x" };
    const ac: Aircraft = .{
        .surfaces = &surf,
        .propulsion = &props,
        .tanks = &tanks,
        .gear = .{ .layout = layouts[src.index(layouts.len)], .main_track = F(src, 0.05, 1.5), .main_z = F(src, 0, 0.4) },
        .fuselage = .{ .enabled = src.boolean(), .length = F(src, 0.1, 3), .width = F(src, 0.02, 0.5), .height = F(src, 0.02, 0.5) },
        .boom = .{ .enabled = src.boolean(), .length = F(src, 0.1, 3), .diameter = F(src, 0.005, 0.1) },
        .ballast = .{ .enabled = src.boolean(), .mass = F(src, 0, 5) },
        .payload = .{ .enabled = src.boolean(), .x = F(src, -1, 1) },
    };
    var d: model.Diag = .{};
    var sk = build(testing.allocator, &ac, &d) catch |e| {
        try testing.expect(d.len > 0 or e == error.OutOfMemory);
        return;
    };
    defer sk.deinit();
    try checkSkeleton(&sk);
}

test "fuzz: esqueleto de geometria qualquer" {
    try fz.check({}, fuzzBuild, .{});
}
