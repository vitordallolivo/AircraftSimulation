//! Câmeras: cada uma é um objeto com a mesma interface (`update` + `view`); a tela só pede a vista.
//! Coordenadas do mundo em NED (n, e, d), como o núcleo; o desenho converte para a tela.
//!
//! Por enquanto: `orbit` (hangar e telas de configuração). Próximas (mesma interface): piloto no
//! chão (parado, só os "olhos" seguem; zoom automático), perseguição, cabine, de cima, zoom em peça.
const std = @import("std");
const fz = @import("../util/fuzz.zig");
const v3 = @import("../math/vec3.zig");

const V3 = v3.V3;

pub const View = struct {
    eye: V3,
    target: V3,
    up: V3 = .{ 0, 0, -1 }, // para cima = −d
    fov_deg: f64 = 45,
};

/// o que a câmera recebe por quadro (mouse/analógico já convertidos)
pub const Input = struct {
    drag: [2]f64 = .{ 0, 0 }, // px (girar)
    zoom: f64 = 0, // passos da roda (+ aproxima)
    target: ?V3 = null, // o que seguir (ex.: a aeronave)
};

pub const Orbit = struct {
    target: V3 = .{ 0, 0, 0 },
    distance: f64 = 4.0,
    azimuth_deg: f64 = 130, // a partir do nariz (+n), girando para a direita (+e)
    elevation_deg: f64 = 22, // acima do horizonte
    fov_deg: f64 = 45,
    min_distance: f64 = 0.3,
    max_distance: f64 = 200,

    /// enquadra um objeto de raio r (a vista inicial da GUI: atrás, à direita, por cima)
    pub fn framing(r: f64) Orbit {
        const rr = if (std.math.isFinite(r) and r > 0.05) @min(r, 100.0) else 1.0;
        return .{ .distance = std.math.clamp(2.2 * rr, 0.5, 150), .min_distance = 0.3 * rr, .max_distance = 40 * rr };
    }

    pub fn update(o: *Orbit, in: Input, dt: f64) void {
        _ = dt;
        if (std.math.isFinite(in.drag[0]) and std.math.isFinite(in.drag[1])) {
            o.azimuth_deg = @mod(o.azimuth_deg + 0.4 * std.math.clamp(in.drag[0], -2000, 2000), 360);
            o.elevation_deg = std.math.clamp(o.elevation_deg + 0.4 * std.math.clamp(in.drag[1], -2000, 2000), -85, 85);
        }
        if (std.math.isFinite(in.zoom)) o.distance *= std.math.pow(f64, 0.9, std.math.clamp(in.zoom, -20, 20));
        o.distance = std.math.clamp(o.distance, o.min_distance, o.max_distance);
        if (in.target) |t| if (v3.finite(t) and v3.norm(t) < 1e7) { // mundo: até 10 000 km
            o.target = t;
        };
    }

    pub fn view(o: *const Orbit) View {
        const az = std.math.degreesToRadians(o.azimuth_deg);
        const el = std.math.degreesToRadians(o.elevation_deg);
        const dir: V3 = .{ @cos(el) * @cos(az), @cos(el) * @sin(az), -@sin(el) };
        return .{ .eye = v3.add(o.target, v3.scale(dir, o.distance)), .target = o.target, .fov_deg = o.fov_deg };
    }
};

/// a interface: uma câmera é qualquer um destes
pub const Camera = union(enum) {
    orbit: Orbit,

    pub fn update(c: *Camera, in: Input, dt: f64) void {
        switch (c.*) {
            inline else => |*x| x.update(in, dt),
        }
    }
    pub fn view(c: *const Camera) View {
        return switch (c.*) {
            inline else => |*x| x.view(),
        };
    }
};

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "órbita inicial: atrás, à direita e acima do alvo (como a GUI)" {
    var c: Camera = .{ .orbit = Orbit.framing(1.5) };
    const v = c.view();
    try testing.expect(v.eye[0] < 0 and v.eye[1] > 0 and v.eye[2] < 0);
}

fn fuzzCamera(_: void, src: *fz.Src) anyerror!void {
    // entradas quaisquer em sequência: a vista continua finita, com o olho fora do alvo
    var c: Camera = .{ .orbit = Orbit.framing(src.any()) };
    while (!src.chance(8)) {
        const f = struct {
            fn f(s: *fz.Src) f64 {
                return s.any();
            }
        }.f;
        c.update(.{ .drag = .{ f(src), f(src) }, .zoom = f(src), .target = if (src.boolean()) .{ f(src), f(src), f(src) } else null }, 1.0 / 60.0);
        const v = c.view();
        try testing.expect(v3.finite(v.eye) and v3.finite(v.target));
        // olho na distância pedida (até a precisão do f64 na posição do alvo) e dentro dos limites
        const o = c.orbit;
        try testing.expect(o.distance >= o.min_distance and o.distance <= o.max_distance);
        try testing.expectApproxEqAbs(o.distance, v3.norm(v3.sub(v.eye, v.target)), 1e-9 * (1 + v3.norm(v.target)));
    }
}

test "fuzz: câmera" {
    try fz.check({}, fuzzCamera, .{});
}
