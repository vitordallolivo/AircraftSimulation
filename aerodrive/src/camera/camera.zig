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
    heading: ?f64 = null, // proa da aeronave (rad) — a perseguição usa
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

/// atrás da aeronave, a uma distância fixa, com atraso suave (segue a proa)
pub const Chase = struct {
    target: V3 = .{ 0, 0, 0 },
    heading: f64 = 0, // rad (proa seguida, suavizada)
    distance: f64 = 6,
    height: f64 = 1.8,
    fov_deg: f64 = 55,
    lag: f64 = 1.5, // s (constante do atraso da proa)

    pub fn update(c: *Chase, in: Input, dt: f64) void {
        if (in.target) |t| if (v3.finite(t) and v3.norm(t) < 1e7) {
            c.target = t;
        };
        if (in.heading) |h| if (std.math.isFinite(h)) {
            const d = std.math.atan2(@sin(h - c.heading), @cos(h - c.heading)); // menor ângulo
            const k = if (std.math.isFinite(dt) and dt > 0) std.math.clamp(dt / c.lag, 0, 1) else 0;
            c.heading = @mod(c.heading + k * d + std.math.pi, 2 * std.math.pi) - std.math.pi;
        };
        if (std.math.isFinite(in.zoom)) c.distance = std.math.clamp(c.distance * std.math.pow(f64, 0.9, std.math.clamp(in.zoom, -20, 20)), 1.5, 60);
    }

    pub fn view(c: *const Chase) View {
        const back: V3 = .{ -@cos(c.heading) * c.distance, -@sin(c.heading) * c.distance, -c.height };
        return .{ .eye = v3.add(c.target, back), .target = c.target, .fov_deg = c.fov_deg };
    }
};

/// o piloto parado no chão: só os "olhos" seguem a aeronave; o zoom (fov) mantém o avião num
/// tamanho visível na tela até longe (como no SeligSIM/RealFlight)
pub const Ground = struct {
    eye: V3 = .{ -8, 12, -1.7 }, // atrás e à direita da cabeceira, na altura dos olhos
    target: V3 = .{ 0, 0, 0 },
    size: f64 = 2.5, // envergadura (m)
    screen_frac: f64 = 0.18, // fração da tela que o avião ocupa (de longe)
    max_fov: f64 = 70,
    min_fov: f64 = 6,

    pub fn update(g: *Ground, in: Input, dt: f64) void {
        _ = dt;
        if (in.target) |t| if (v3.finite(t) and v3.norm(t) < 1e7) {
            g.target = t;
        };
        if (std.math.isFinite(in.zoom)) g.screen_frac = std.math.clamp(g.screen_frac * std.math.pow(f64, 1.1, std.math.clamp(in.zoom, -20, 20)), 0.03, 0.6);
    }

    pub fn view(g: *const Ground) View {
        const dist = @max(v3.norm(v3.sub(g.target, g.eye)), 0.5);
        const fov = 2 * std.math.atan(g.size / (2 * dist * g.screen_frac));
        return .{ .eye = g.eye, .target = if (dist > 0.5) g.target else v3.add(g.eye, .{ 1, 0, 0 }), .fov_deg = std.math.clamp(std.math.radiansToDegrees(fov), g.min_fov, g.max_fov) };
    }
};

/// a interface: uma câmera é qualquer um destes
pub const Camera = union(enum) {
    orbit: Orbit,
    chase: Chase,
    ground: Ground,

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
    var c: Camera = switch (src.int(u8, 0, 2)) {
        0 => .{ .orbit = Orbit.framing(src.any()) },
        1 => .{ .chase = .{} },
        else => .{ .ground = .{} },
    };
    while (!src.chance(8)) {
        const f = struct {
            fn f(s: *fz.Src) f64 {
                return s.any();
            }
        }.f;
        c.update(.{ .drag = .{ f(src), f(src) }, .zoom = f(src), .target = if (src.boolean()) .{ f(src), f(src), f(src) } else null, .heading = if (src.boolean()) f(src) else null }, if (src.chance(5)) f(src) else 1.0 / 60.0);
        const v = c.view();
        try testing.expect(v3.finite(v.eye) and v3.finite(v.target));
        try testing.expect(v.fov_deg > 1 and v.fov_deg < 120);
        if (c != .orbit) continue;
        // olho na distância pedida (até a precisão do f64 na posição do alvo) e dentro dos limites
        const o = c.orbit;
        try testing.expect(o.distance >= o.min_distance and o.distance <= o.max_distance);
        try testing.expectApproxEqAbs(o.distance, v3.norm(v3.sub(v.eye, v.target)), 1e-9 * (1 + v3.norm(v.target)));
    }
}

test "fuzz: câmera" {
    try fz.check({}, fuzzCamera, .{});
}
