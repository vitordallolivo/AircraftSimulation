//! Percurso -> segmentos, eventos e mesas/plataformas do núcleo (`aerosim/model/mission.py` e
//! `Airfield.pads` portados). Cada perna começa onde a anterior terminou.
const std = @import("std");
const core = @import("aerosim");
const model = @import("../model/aircraft.zig");
const fz = @import("../util/fuzz.zig");

const T = core.types;
const L = core.limits;

pub const auto_phi_deg = 45.0; // raio automático (perna com raio 0): R = V²/(g tan φ)

pub fn autoRadius(V: f64) f64 {
    return @max(V * V / (9.80665 * @tan(std.math.degreesToRadians(auto_phi_deg))), 3.0);
}

pub const Error = error{ TooManySegments, TooManyEvents, BadLeg };

/// segmentos do núcleo (SI, rad); devolve quantos
pub fn segments(m: *const model.Mission, out: *[L.max_segments]T.Segment, diag: *model.Diag) Error!usize {
    if (m.legs.len > L.max_segments) {
        diag.set("percurso: {d} pernas (máximo {d})", .{ m.legs.len, L.max_segments });
        return error.TooManySegments;
    }
    var n = m.n0;
    var e = m.e0;
    var chi = std.math.degreesToRadians(m.chi0);
    var h = m.h0;
    var V = m.V0;
    for (m.legs, 0..) |p, k| {
        const h1 = p.h orelse h;
        const V1 = p.V orelse V;
        inline for (.{ h1, V1, p.length, p.radius, p.angle }) |x| {
            if (!std.math.isFinite(x) or @abs(x) > 1e6) {
                diag.set("percurso: perna '{s}' com número inválido", .{p.name});
                return error.BadLeg;
            }
        }
        var sg: T.Segment = .{ .h0 = h, .h1 = h1, .V0 = V, .V1 = V1, .takeoff = @intFromBool(p.takeoff), .landing = @intFromBool(p.landing), .clearance = p.clearance };
        if (!std.mem.eql(u8, p.kind, "turn")) {
            sg.arc = 0;
            sg.n0 = n;
            sg.e0 = e;
            sg.chi0 = chi;
            sg.L = p.length;
            n += p.length * @cos(chi);
            e += p.length * @sin(chi);
        } else {
            const lam: f64 = if (p.side < 0) -1 else 1;
            const a = std.math.degreesToRadians(p.angle);
            const R = if (p.radius > 0) p.radius else autoRadius(@max(V, V1));
            const cn = n + R * @cos(chi + lam * std.math.pi / 2.0);
            const ce = e + R * @sin(chi + lam * std.math.pi / 2.0);
            sg.arc = 1;
            sg.n0 = n;
            sg.e0 = e;
            sg.cn = cn;
            sg.ce = ce;
            sg.R = R;
            sg.lam = lam;
            sg.L = R * a;
            sg.chi0 = chi;
            const fi = std.math.atan2(e - ce, n - cn) + lam * a;
            n = cn + R * @cos(fi);
            e = ce + R * @sin(fi);
            chi += lam * a;
        }
        out[k] = sg;
        h = h1;
        V = V1;
    }
    if (m.legs.len > 0 and m.legs[0].takeoff) out[0].h0 = out[0].h1;
    return m.legs.len;
}

pub fn events(m: *const model.Mission, out: *[L.max_events]T.Event, diag: *model.Diag) Error!usize {
    if (m.events.len > L.max_events) {
        diag.set("percurso: {d} eventos (máximo {d})", .{ m.events.len, L.max_events });
        return error.TooManyEvents;
    }
    for (m.events, 0..) |ev, k| {
        if (ev.leg < 0 or ev.leg >= @as(i64, @intCast(@max(m.legs.len, 1))) or !std.math.isFinite(ev.s)) {
            diag.set("percurso: evento '{s}' fora das pernas", .{ev.kind});
            return error.BadLeg;
        }
        out[k] = .{ .kind = if (std.mem.eql(u8, ev.kind, "drop")) T.event_drop else T.event_gust, .seg = @intCast(ev.leg), .s = ev.s };
    }
    return m.events.len;
}

/// mesa (decolagem) e plataforma (na última perna de pouso reta)
pub fn pads(af: *const model.Airfield, segs: []const T.Segment, out: *[L.max_pads]T.Pad) usize {
    var k: usize = 0;
    if (std.mem.eql(u8, af.takeoff_from, "mesa") and af.table_height > 0) {
        out[k] = .{ .n0 = -af.table_back, .e0 = 0, .chi = 0, .L = af.table_back + af.table_length, .W = af.table_width, .h = af.table_height };
        k += 1;
    }
    if (std.mem.eql(u8, af.landing_on, "plataforma") and af.platform_height > 0 and k < out.len) {
        var i = segs.len;
        while (i > 0) {
            i -= 1;
            const ld = segs[i];
            if (ld.landing != 0 and ld.arc == 0) {
                const st = @max(ld.L - af.platform_start, 0.0);
                out[k] = .{ .n0 = ld.n0 + st * @cos(ld.chi0), .e0 = ld.e0 + st * @sin(ld.chi0), .chi = ld.chi0, .L = af.platform_length, .W = af.platform_width, .h = af.platform_height };
                k += 1;
                break;
            }
        }
    }
    return k;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "circuito: curva de 180° volta paralela; perna seguinte começa no fim da anterior" {
    const legs = [_]model.Leg{
        .{ .kind = "straight", .length = 100, .h = 15, .V = 15, .takeoff = true },
        .{ .kind = "turn", .radius = 50, .angle = 180, .side = 1 },
        .{ .kind = "straight", .length = 100, .landing = true },
    };
    var out: [L.max_segments]T.Segment = undefined;
    var d: model.Diag = .{};
    const m: model.Mission = .{ .legs = &legs, .h0 = 15, .V0 = 15 };
    const n = try segments(&m, &out, &d);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectApproxEqAbs(@as(f64, 100), out[2].n0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 100), out[2].e0, 1e-9);
    try testing.expectApproxEqAbs(std.math.pi, out[2].chi0, 1e-12);
    var pd: [L.max_pads]T.Pad = undefined;
    const af: model.Airfield = .{ .takeoff_from = "mesa", .landing_on = "plataforma", .platform_start = 50 };
    try testing.expectEqual(@as(usize, 2), pads(&af, out[0..n], &pd));
    try testing.expectApproxEqAbs(@as(f64, 50), pd[1].n0, 1e-9);
}

fn fuzzMission(_: void, src: *fz.Src) anyerror!void {
    var legs: [40]model.Leg = undefined;
    const nl = src.int(u8, 0, 40);
    for (legs[0..nl]) |*l| l.* = .{
        .kind = if (src.boolean()) "turn" else "straight",
        .length = src.mostly(0, 500),
        .radius = src.mostly(0, 200),
        .angle = src.mostly(-360, 360),
        .side = src.mostly(-1, 1),
        .h = if (src.boolean()) src.mostly(0, 100) else null,
        .V = if (src.boolean()) src.mostly(5, 30) else null,
        .takeoff = src.boolean(),
        .landing = src.boolean(),
    };
    const m: model.Mission = .{ .legs = legs[0..nl], .h0 = src.mostly(0, 50), .V0 = src.mostly(5, 30) };
    var out: [L.max_segments]T.Segment = undefined;
    var d: model.Diag = .{};
    const n = segments(&m, &out, &d) catch {
        try testing.expect(d.len > 0);
        return;
    };
    for (out[0..n]) |s| inline for (.{ "n0", "e0", "chi0", "L", "R", "h0", "h1", "V0", "V1" }) |f| try testing.expect(std.math.isFinite(@field(s, f)));
    var pd: [L.max_pads]T.Pad = undefined;
    _ = pads(&.{ .takeoff_from = "mesa", .landing_on = "plataforma" }, out[0..n], &pd);
}

test "fuzz: percurso" {
    try fz.check({}, fuzzMission, .{});
}
