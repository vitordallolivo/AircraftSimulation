//! O que a aeronave tem — para as telas se montarem sozinhas: quais canais de comando existem
//! (e por qual superfície: profundor, elevon, ruddervator, aileron, leme), se tem motor, LAPES,
//! tanques com líquido. Nada aqui conhece a tela.
const std = @import("std");
const model = @import("aircraft.zig");
const sk = @import("skeleton.zig");
const airfoil = @import("airfoil.zig");
const v3 = @import("../math/vec3.zig");
const fz = @import("../util/fuzz.zig");

/// os canais de comando que um piloto pode ter
pub const Channel = enum {
    throttle,
    aileron,
    elevator,
    rudder,

    pub fn label(c: Channel) [:0]const u8 {
        return switch (c) {
            .throttle => "Motor",
            .aileron => "Aileron",
            .elevator => "Profundor (EH)",
            .rudder => "Leme (EV)",
        };
    }
};

pub const Features = struct {
    throttle: bool = false,
    /// superfície que faz cada eixo (vazio = não tem)
    roll_by: []const u8 = "",
    pitch_by: []const u8 = "",
    yaw_by: []const u8 = "",
    payload: bool = false,
    tanks: usize = 0,
    props: usize = 0,

    pub fn has(f: Features, c: Channel) bool {
        return switch (c) {
            .throttle => f.throttle,
            .aileron => f.roll_by.len > 0,
            .elevator => f.pitch_by.len > 0,
            .rudder => f.yaw_by.len > 0,
        };
    }

    /// os canais que existem, na ordem da tela
    pub fn channels(f: Features, out: *[4]Channel) []const Channel {
        var n: usize = 0;
        inline for (.{ Channel.throttle, Channel.aileron, Channel.elevator, Channel.rudder }) |c| {
            if (f.has(c)) {
                out[n] = c;
                n += 1;
            }
        }
        return out[0..n];
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn detect(ac: *const model.Aircraft) Features {
    var f: Features = .{};
    for (ac.propulsion) |u| {
        if (u.enabled) f.props += 1;
    }
    f.throttle = f.props > 0;
    for (ac.surfaces) |s| {
        if (!s.enabled) continue;
        for (s.controls) |c| {
            const k = c.role(); // pela mistura: o nome do comando é livre
            if (eq(k, "aileron") and f.roll_by.len == 0) f.roll_by = "aileron";
            if (eq(k, "elevon")) {
                if (f.roll_by.len == 0 or eq(f.roll_by, "aileron") == false) f.roll_by = "elevon";
                if (f.pitch_by.len == 0) f.pitch_by = "elevon";
            }
            if (eq(k, "elevator")) f.pitch_by = "profundor";
            if (eq(k, "rudder")) f.yaw_by = "leme";
            if (eq(k, "ruddervator")) {
                if (f.pitch_by.len == 0) f.pitch_by = "ruddervator";
                if (f.yaw_by.len == 0) f.yaw_by = "ruddervator";
            }
            const g = c.gains(); // mistura livre (ex.: leme-aileron): o canal vem pelo nome que o projetista deu
            if (g[0] != 0 and f.pitch_by.len == 0) f.pitch_by = c.kind;
            if (g[1] != 0 and f.roll_by.len == 0) f.roll_by = c.kind;
            if (g[2] != 0 and f.yaw_by.len == 0) f.yaw_by = c.kind;
        }
    }
    f.payload = ac.payload.enabled;
    f.tanks = ac.tanks.len;
    return f;
}

/// deflexão máxima útil de um canal (rad), por causa do estol da superfície: o comando muda o
/// ângulo efetivo da seção em τ·δ (τ = efetividade do comando: do arquivo, ou pelo perfil fino
/// com a corda do comando); a seção estola perto de 12°. δ_estol = 12° / τ, no máximo 30°, e vale
/// a superfície que estola primeiro. Motor (ou canal sem superfície): null.
pub const section_stall_deg: f64 = 12;
pub const max_deflection_deg: f64 = 30;

pub fn stallLimit(ac: *const model.Aircraft, c: Channel) ?f64 {
    if (c == .throttle) return null;
    var best: ?f64 = null;
    for (ac.surfaces) |s| {
        if (!s.enabled) continue;
        for (s.controls) |ct| {
            const g = ct.gains();
            const hit = switch (c) {
                .aileron => g[1] != 0,
                .elevator => g[0] != 0,
                .rudder => g[2] != 0,
                .throttle => false,
            };
            if (!hit) continue;
            const tau_raw = ct.tau orelse airfoil.flapEffectiveness(if (std.math.isFinite(ct.chord_frac)) ct.chord_frac else 0.25);
            const tau = if (std.math.isFinite(tau_raw)) std.math.clamp(tau_raw, 0.05, 1) else 0.5;
            const lim = std.math.degreesToRadians(@min(section_stall_deg / tau, max_deflection_deg));
            best = if (best) |b| @min(b, lim) else lim;
        }
    }
    return best;
}

/// onde olhar para ver um canal funcionando (zoom na peça): ponto no corpo e tamanho da peça.
/// Superfícies: a do lado direito (y ≥ 0) quando houver duas; motor: o primeiro cubo da hélice.
pub const Focus = struct { p: v3.V3, size: f64 };

pub fn focus(skel: *const sk.Skeleton, c: Channel) ?Focus {
    var best: ?Focus = null;
    var best_y: f64 = -1e9;
    for (skel.pieces) |pc| {
        const p: v3.V3, const hit = switch (pc.driver) {
            .hinge => |h| .{ h.p, switch (c) {
                .elevator => h.mix[0] != 0,
                .aileron => h.mix[1] != 0,
                .rudder => h.mix[2] != 0,
                .throttle => false,
            } },
            .spin => |sp| .{ sp.p, c == .throttle },
            else => .{ v3.V3{ 0, 0, 0 }, false },
        };
        if (!hit or !v3.finite(p)) continue;
        var lo: v3.V3 = .{ 1e9, 1e9, 1e9 };
        var hi: v3.V3 = .{ -1e9, -1e9, -1e9 };
        for (pc.mesh.v) |q| for (0..3) |k| {
            lo[k] = @min(lo[k], q[k]);
            hi[k] = @max(hi[k], q[k]);
        };
        const size = if (pc.mesh.v.len > 0) std.math.clamp(v3.norm(v3.sub(hi, lo)), 0.05, 20) else 0.3;
        const mid = if (pc.mesh.v.len > 0) v3.scale(v3.add(lo, hi), 0.5) else p;
        if (best == null or mid[1] > best_y + 1e-6) { // o da direita
            best = .{ .p = mid, .size = size };
            best_y = mid[1];
        }
    }
    return best;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "zoom: acha o profundor e o aileron direito do Convencional" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", testing.allocator, .limited(1 << 24));
    defer testing.allocator.free(bytes);
    var d: model.Diag = .{};
    var l = try model.parse(testing.allocator, bytes, &d);
    defer l.deinit();
    var s = try sk.build(testing.allocator, &l.ac, &d);
    defer s.deinit();
    const e = focus(&s, .elevator).?;
    const a = focus(&s, .aileron).?;
    try testing.expect(e.p[0] < a.p[0]); // profundor atrás da asa
    try testing.expect(a.p[1] > 0); // o da direita
    try testing.expect(focus(&s, .throttle) != null);
}

test "convencional: os quatro canais; asa voadora: elevon faz arfagem e rolagem" {
    const secs = [_]model.Section{ .{ .y = 0, .chord = 0.3 }, .{ .y = 1, .chord = 0.3 } };
    const ail = [_]model.Control{.{ .kind = "aileron" }};
    const ele = [_]model.Control{.{ .kind = "elevator" }};
    const rud = [_]model.Control{.{ .kind = "rudder" }};
    const conv = [_]model.Surface{ .{ .sections = &secs, .controls = &ail }, .{ .sections = &secs, .controls = &ele }, .{ .sections = &secs, .controls = &rud } };
    const props = [_]model.Propulsion{.{}};
    var buf: [4]Channel = undefined;
    const f = detect(&.{ .surfaces = &conv, .propulsion = &props });
    try testing.expectEqual(@as(usize, 4), f.channels(&buf).len);
    const elevon = [_]model.Control{.{ .kind = "elevon" }};
    const fw = [_]model.Surface{.{ .sections = &secs, .controls = &elevon }};
    const g = detect(&.{ .surfaces = &fw });
    try testing.expectEqualStrings("elevon", g.pitch_by);
    try testing.expectEqualStrings("elevon", g.roll_by);
    try testing.expect(!g.has(.rudder) and !g.has(.throttle));
}

test "estol do comando: corda maior estola antes; motor não tem" {
    const secs = [_]model.Section{ .{ .y = 0, .chord = 0.3 }, .{ .y = 1, .chord = 0.3 } };
    const small = [_]model.Control{.{ .kind = "elevator", .chord_frac = 0.15 }};
    const big = [_]model.Control{.{ .kind = "elevator", .chord_frac = 0.45 }};
    const a = stallLimit(&.{ .surfaces = &.{.{ .sections = &secs, .controls = &small }} }, .elevator).?;
    const b = stallLimit(&.{ .surfaces = &.{.{ .sections = &secs, .controls = &big }} }, .elevator).?;
    try testing.expect(b < a);
    try testing.expect(a <= std.math.degreesToRadians(30.0) + 1e-12);
    try testing.expect(stallLimit(&.{ .surfaces = &.{.{ .sections = &secs, .controls = &small }} }, .throttle) == null);
    try testing.expect(stallLimit(&.{ .surfaces = &.{.{ .sections = &secs, .controls = &small }} }, .aileron) == null);
}

fn fuzzDetect(_: void, src: *fz.Src) anyerror!void {
    const kinds = [_][]const u8{ "aileron", "elevator", "rudder", "elevon", "ruddervator", "flap", "", "x" };
    var ctl: [6]model.Control = undefined;
    for (&ctl) |*c| c.* = .{ .kind = kinds[src.index(kinds.len)], .chord_frac = src.any(), .tau = if (src.boolean()) src.any() else null };
    const secs = [_]model.Section{ .{ .y = 0 }, .{ .y = 1 } };
    var surfs: [3]model.Surface = undefined;
    for (&surfs, 0..) |*s, i| s.* = .{ .sections = &secs, .controls = ctl[i * 2 .. i * 2 + src.int(u8, 0, 2)], .enabled = src.boolean() };
    const f = detect(&.{ .surfaces = surfs[0..src.int(u8, 0, 3)] });
    var buf: [4]Channel = undefined;
    for (f.channels(&buf)) |c| try testing.expect(f.has(c));
    inline for (.{ Channel.aileron, Channel.elevator, Channel.rudder }) |c| if (stallLimit(&.{ .surfaces = surfs[0..3] }, c)) |l| {
        try testing.expect(std.math.isFinite(l) and l > 0 and l <= std.math.degreesToRadians(30.0) + 1e-12);
    };
}

test "fuzz: recursos do avião" {
    try fz.check({}, fuzzDetect, .{});
}
