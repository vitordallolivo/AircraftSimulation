//! Onde cada peça está num instante: driver da peça + estado do voo -> transformação rígida.
//! Sem gráficos (o `render.zig` só aplica o que sai daqui), então dá para testar e fazer fuzzing.
//!
//! Sistemas: corpo (x frente, y direita, z baixo) -> NED (n, e, d) pela atitude e posição.
const std = @import("std");
const fz = @import("../util/fuzz.zig");
const v3 = @import("../math/vec3.zig");
const sk = @import("../model/skeleton.zig");

const V3 = v3.V3;
const M3 = v3.M3;

pub const max_units = 8;
pub const max_tanks = 8;
pub const max_deflection = std.math.degreesToRadians(60.0); // satura comandos absurdos

/// o que move as peças (vem da fonte do estado: voo ao vivo ou o controle nos menus)
pub const DriveState = struct {
    de: f64 = 0, // rad
    da: f64 = 0,
    dr: f64 = 0,
    prop_angle: [max_units]f64 = @splat(0), // rad (integrado a partir do rpm pela fonte)
    slosh_tilt: [max_tanks][2]f64 = @splat(.{ 0, 0 }), // rad: em torno de x e de y do corpo
    payload_released: bool = false,
};

/// v' = R v + t (no corpo)
pub const Rigid = struct {
    R: M3 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } },
    t: V3 = .{ 0, 0, 0 },
    visible: bool = true,

    pub fn apply(r: Rigid, v: V3) V3 {
        return v3.add(v3.apply(r.R, v), r.t);
    }
    /// primeiro `a`, depois `b`
    pub fn then(a: Rigid, b: Rigid) Rigid {
        return .{ .R = v3.matmul(b.R, a.R), .t = b.apply(a.t), .visible = a.visible and b.visible };
    }
};

fn sane(x: f64, lim: f64) f64 {
    if (!std.math.isFinite(x)) return 0;
    return std.math.clamp(x, -lim, lim);
}

/// rotação de `ang` em torno do eixo que passa por `p` com direção `d`
pub fn about(p: V3, d: V3, ang: f64) Rigid {
    const R = v3.axisAngle(v3.unit(d, .{ 0, 0, 1 }), ang);
    return .{ .R = R, .t = v3.sub(p, v3.apply(R, p)) };
}

/// transformação da peça no corpo
pub fn piece(drv: sk.Driver, s: DriveState) Rigid {
    return switch (drv) {
        .fixed => .{},
        .hinge => |h| blk: {
            const cmd = h.mix[0] * sane(s.de, max_deflection) + h.mix[1] * sane(s.da, max_deflection) + h.mix[2] * sane(s.dr, max_deflection);
            break :blk about(h.p, h.d, sane(cmd + std.math.degreesToRadians(h.angle_deg), 2 * max_deflection));
        },
        .spin => |sp| about(sp.p, sp.d, sp.sense * @mod(sane(s.prop_angle[@min(sp.unit, max_units - 1)], 1e9), 2 * std.math.pi)),
        .liquid => |lq| blk: {
            const t = s.slosh_tilt[@min(lq.tank, max_tanks - 1)];
            const rx = about(lq.p, .{ 1, 0, 0 }, sane(t[0], 0.6));
            break :blk rx.then(about(lq.p, .{ 0, 1, 0 }, sane(t[1], 0.6)));
        },
        .payload => .{ .visible = !s.payload_released },
    };
}

/// corpo -> NED: atitude (φ, θ, ψ) e posição (n, e, d)
pub fn body(pos_ned: V3, phi: f64, theta: f64, psi: f64) Rigid {
    return .{ .R = v3.bodyToNed(sane(phi, 1e3), sane(theta, 1e3), sane(psi, 1e3)), .t = .{ sane(pos_ned[0], 1e7), sane(pos_ned[1], 1e7), sane(pos_ned[2], 1e7) } };
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "profundor +10° desce o bordo de fuga; hélice gira em torno do eixo" {
    const h: sk.Driver = .{ .hinge = .{ .p = .{ -1, 0, 0 }, .d = .{ 0, 1, 0 }, .mix = .{ 1, 0, 0 }, .angle_deg = 0 } };
    const r = piece(h, .{ .de = std.math.degreesToRadians(10.0) });
    const te = r.apply(.{ -1.2, 0, 0 });
    try testing.expect(te[2] > 0.03);
    try testing.expectApproxEqAbs(@as(f64, 0), r.apply(.{ -1, 0.3, 0 })[2], 1e-12); // a articulação não se move
    const sp: sk.Driver = .{ .spin = .{ .p = .{ 0.5, 0, 0 }, .d = .{ 1, 0, 0 }, .unit = 0, .sense = 1 } };
    var st: DriveState = .{};
    st.prop_angle[0] = std.math.pi / 2.0;
    const q = piece(sp, st).apply(.{ 0.5, 0.2, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0.2), q[2], 1e-12);
}

test "LAPES some do avião depois da soltura" {
    try testing.expect(!piece(.{ .payload = .{ .r = .{ 0, 0, 0 } } }, .{ .payload_released = true }).visible);
}

fn fuzzPose(_: void, src: *fz.Src) anyerror!void {
    // estado qualquer (NaN, ±inf, enormes): a transformação é finita e rígida (preserva distâncias)
    const f = struct {
        fn f(s: *fz.Src) f64 {
            return s.any();
        }
    }.f;
    var st: DriveState = .{ .de = f(src), .da = f(src), .dr = f(src), .payload_released = src.boolean() };
    for (&st.prop_angle) |*a| a.* = f(src);
    for (&st.slosh_tilt) |*t| t.* = .{ f(src), f(src) };
    const drivers = [_]sk.Driver{
        .fixed,
        .{ .hinge = .{ .p = .{ f(src), 0, 0 }, .d = .{ f(src), f(src), f(src) }, .mix = .{ f(src), f(src), f(src) }, .angle_deg = f(src) } },
        .{ .spin = .{ .p = .{ 0, 0, 0 }, .d = .{ 1, f(src), 0 }, .unit = src.int(u8, 0, 255), .sense = 1 } },
        .{ .liquid = .{ .tank = src.int(u8, 0, 255), .p = .{ 0, 0, 0 } } },
        .{ .payload = .{ .r = .{ 0, 0, 0 } } },
    };
    const drv = drivers[src.index(drivers.len)];
    if (drv == .hinge and !(v3.finite(drv.hinge.p) and @abs(drv.hinge.p[0]) < 1e3)) return; // o esqueleto só gera pontos finitos
    var r = piece(drv, st);
    r = r.then(body(.{ f(src), f(src), f(src) }, f(src), f(src), f(src)));
    const a: V3 = .{ 0.3, -0.2, 0.1 };
    const b: V3 = .{ -0.5, 0.4, 0.0 };
    const pa = r.apply(a);
    const pb = r.apply(b);
    try testing.expect(v3.finite(pa) and v3.finite(pb));
    try testing.expectApproxEqAbs(v3.norm(v3.sub(a, b)), v3.norm(v3.sub(pa, pb)), 1e-6 * (1 + v3.norm(pa)));
}

test "fuzz: pose de qualquer peça" {
    try fz.check({}, fuzzPose, .{});
}
